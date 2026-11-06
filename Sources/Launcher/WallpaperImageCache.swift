import AppKit
@preconcurrency import AVFoundation
import ColorSync
import CoreImage
import CoreImage.CIFilterBuiltins
import Diagnostics
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum WallpaperSourceKind: String, Equatable, Hashable, Sendable {
    case windowCapture
    case staticImage
    case aerialVideo
    case unavailable
}

struct WallpaperSource: Equatable, Sendable {
    let kind: WallpaperSourceKind
    let url: URL?
    let windowID: CGWindowID?
    let captureBounds: CGRect?

    init(
        kind: WallpaperSourceKind,
        url: URL?,
        windowID: CGWindowID? = nil,
        captureBounds: CGRect? = nil
    ) {
        self.kind = kind
        self.url = url
        self.windowID = windowID
        self.captureBounds = captureBounds
    }

    static let unavailable = WallpaperSource(kind: .unavailable, url: nil)
}

/// The small, value-only subset of WindowServer metadata needed to identify a
/// wallpaper window. Keeping this separate from the CoreGraphics dictionary
/// makes filtering and per-display selection testable without a live desktop.
struct WallpaperWindowCandidate: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerName: String
    let windowName: String
    let layer: Int
    let bounds: CGRect
    let isOnscreen: Bool
    let alpha: Double
}

/// Resolves the image that macOS is actually using for a display.
///
/// File sources come first — the workspace image, then the artwork of the
/// provider the system wallpaper store names, then the configured Aerial — and
/// a WindowServer wallpaper window is captured only when none of them is
/// usable. `NSWorkspace` reports `DefaultDesktop.heic` for any desktop an
/// extension draws, which is why that placeholder never counts as a source.
enum WallpaperSourceResolver {
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    private static let wallpaperLayerThreshold = -2_000_000_000

    static func resolve(
        desktopURL: URL?,
        configuredURL: URL?,
        providerArtworkURL: URL? = nil
    ) -> WallpaperSource {
        resolve(
            desktopURL: desktopURL,
            configuredURL: configuredURL,
            providerArtworkURL: providerArtworkURL,
            isUsableFile: isUsableFile
        )
    }

    /// The injected file predicate keeps source selection testable without a
    /// live `NSScreen` or a user's wallpaper files.
    static func resolve(
        desktopURL: URL?,
        configuredURL: URL?,
        providerArtworkURL: URL? = nil,
        isUsableFile: (URL) -> Bool
    ) -> WallpaperSource {
        if let desktopURL,
           isUsableFile(desktopURL),
           !isDefaultDesktopURL(desktopURL) {
            return source(for: desktopURL)
        }

        // Ahead of the configured Aerial on purpose. `SystemWallpaperURL` can
        // outlive the wallpaper it named — on the machine this was found on it
        // still pointed at an Aerial that the macOS 27 update had deleted,
        // while the store said the desktop was the new default. The store is
        // what describes the desktop as it is now.
        if let providerArtworkURL, isUsableFile(providerArtworkURL) {
            return source(for: providerArtworkURL)
        }

        if let configuredURL,
           isUsableFile(configuredURL),
           !isDefaultDesktopURL(configuredURL) {
            return source(for: configuredURL)
        }

        // A default placeholder, an absent setting, or an unreadable setting
        // must not make the app display the wrong blue/green system image.
        return .unavailable
    }

    /// Resolves a file-backed wallpaper first, then uses WindowServer only
    /// when macOS exposes no usable file source.
    static func resolve(
        desktopURL: URL?,
        configuredURL: URL?,
        providerArtworkURL: URL? = nil,
        windowCandidates: [WallpaperWindowCandidate],
        targetBounds: CGRect?,
        hasScreenCaptureAccess: Bool = false,
        isUsableFile: (URL) -> Bool
    ) -> WallpaperSource {
        let fileSource = resolve(
            desktopURL: desktopURL,
            configuredURL: configuredURL,
            providerArtworkURL: providerArtworkURL,
            isUsableFile: isUsableFile
        )
        guard fileSource.kind == .unavailable else { return fileSource }

        let capturable = hasScreenCaptureAccess
            ? windowCandidates
            : windowCandidates.filter(isReadableWithoutCaptureAccess)
        if let candidate = selectWallpaperWindow(
            candidates: capturable,
            targetBounds: targetBounds
        ) {
            let captureBounds: CGRect
            if let targetBounds,
               candidate.bounds.intersects(targetBounds) {
                captureBounds = candidate.bounds.intersection(targetBounds)
            } else {
                captureBounds = candidate.bounds
            }
            return WallpaperSource(
                kind: .windowCapture,
                url: nil,
                windowID: candidate.windowID,
                captureBounds: captureBounds
            )
        }

        return fileSource
    }

    static func resolve(
        desktopURL: URL?,
        configuredURL: URL?,
        providerArtworkURL: URL? = nil,
        windowCandidates: [WallpaperWindowCandidate],
        targetBounds: CGRect?,
        hasScreenCaptureAccess: Bool
    ) -> WallpaperSource {
        resolve(
            desktopURL: desktopURL,
            configuredURL: configuredURL,
            providerArtworkURL: providerArtworkURL,
            windowCandidates: windowCandidates,
            targetBounds: targetBounds,
            hasScreenCaptureAccess: hasScreenCaptureAccess,
            isUsableFile: isUsableFile
        )
    }

    /// Whether WindowServer hands this window's real pixels to a process
    /// without Screen Recording access.
    ///
    /// Up to macOS 26 the desktop was drawn into Dock-owned windows, which came
    /// back as the picture — the premise this capture path was built on. macOS
    /// 27 moved it into `WindowManager`, and without the permission those
    /// windows come back as a flat grey stand-in, or, mid-transition, a grey
    /// strip on transparency: never nil, and never the wallpaper. Judging that
    /// from the pixels proved unreliable (the partial stand-in is not a single
    /// colour), so the owner decides, and anything else is not captured at all.
    static func isReadableWithoutCaptureAccess(_ candidate: WallpaperWindowCandidate) -> Bool {
        candidate.ownerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "dock"
    }

    static func isWallpaperWindowCandidate(
        _ candidate: WallpaperWindowCandidate
    ) -> Bool {
        guard candidate.bounds.width > 1,
              candidate.bounds.height > 1,
              candidate.alpha > 0 else {
            return false
        }

        let windowName = candidate.windowName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard windowName.contains("wallpaper") else {
            return false
        }

        let ownerName = candidate.ownerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let knownOwner = ownerName == "dock"
            || ownerName.contains("wallpaper")
            || ownerName.contains("壁紙")
        let knownLayer = candidate.layer <= wallpaperLayerThreshold
        return knownOwner || knownLayer
    }

    /// Returns the best candidate for a display using only immutable metadata.
    /// If any candidates intersect `targetBounds`, candidates from other
    /// displays are discarded; on-screen state and layer then break ties.
    static func selectWallpaperWindow(
        candidates: [WallpaperWindowCandidate],
        targetBounds: CGRect?
    ) -> WallpaperWindowCandidate? {
        let filtered = candidates.filter(isWallpaperWindowCandidate)
        guard !filtered.isEmpty else { return nil }

        let scoped: [WallpaperWindowCandidate]
        if let targetBounds {
            let intersecting = filtered.filter { $0.bounds.intersects(targetBounds) }
            // Never borrow another display's wallpaper when WindowServer
            // reports no candidate for this screen. Returning nil selects the
            // file/Aerial fallback instead of showing a visibly wrong desktop.
            guard !intersecting.isEmpty else { return nil }
            scoped = intersecting
        } else {
            scoped = filtered
        }

        return scoped.max { lhs, rhs in
            if lhs.isOnscreen != rhs.isOnscreen {
                return !lhs.isOnscreen && rhs.isOnscreen
            }
            if lhs.layer != rhs.layer {
                return lhs.layer < rhs.layer
            }
            let lhsIntersection = targetBounds.map { lhs.bounds.intersection($0).width * lhs.bounds.intersection($0).height }
                ?? lhs.bounds.width * lhs.bounds.height
            let rhsIntersection = targetBounds.map { rhs.bounds.intersection($0).width * rhs.bounds.intersection($0).height }
                ?? rhs.bounds.width * rhs.bounds.height
            if lhsIntersection != rhsIntersection {
                return lhsIntersection < rhsIntersection
            }
            return lhs.windowID > rhs.windowID
        }
    }

    private static func source(for url: URL) -> WallpaperSource {
        let kind: WallpaperSourceKind = videoExtensions.contains(url.pathExtension.lowercased())
            ? .aerialVideo
            : .staticImage
        return WallpaperSource(kind: kind, url: url)
    }

    private static func isDefaultDesktopURL(_ url: URL) -> Bool {
        let lastPathComponent = url.lastPathComponent.lowercased()
        if lastPathComponent == "defaultdesktop" || lastPathComponent.hasPrefix("defaultdesktop.") {
            return true
        }
        let path = url.path.lowercased()
        return path.contains("/core services/defaultdesktop")
            || path.contains("/core services/defaultdesktop.")
            || path.contains("/coreservices/defaultdesktop")
            || path.contains("/coreservices/defaultdesktop.")
    }

    private static func isUsableFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}

/// Reads macOS's own record of which wallpaper each display shows.
///
/// macOS 27's default wallpaper is drawn by an ExtensionKit extension rather
/// than read from a file. `NSWorkspace` reports only the `DefaultDesktop.heic`
/// placeholder for it, and the WindowServer windows it is drawn into now
/// belong to `WindowManager`, which hands a process without Screen Recording
/// access a flat grey stand-in instead of the picture. The store is the one
/// place a process without extra permissions can read that says which
/// provider is drawing the desktop, and the default provider's artwork ships
/// inside its extension as a light and a dark still.
enum SystemWallpaperStore {
    static let defaultProviderIdentifier = "com.apple.NeptuneOneExtension"
    static let aerialsProviderIdentifier = "com.apple.wallpaper.choice.aerials"
    /// What the store records once the wallpaper has been set back to the
    /// system's own: no configuration at all, and the provider is just "default".
    static let systemDefaultProviderIdentifier = "default"
    /// Where the user's own pictures come from: macOS 27's image extension, and
    /// the provider earlier versions used.
    static let imageProviderIdentifiers: Set<String> = [
        "com.apple.wallpaper.extension.image",
        "com.apple.wallpaper.choice.image",
    ]

    private static let defaultProviderResources = URL(
        fileURLWithPath: "/System/Library/ExtensionKit/Extensions/NeptuneOneWallpaper.appex/Contents/Resources",
        isDirectory: true
    )

    static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// The still the default provider draws for an appearance. Checked against
    /// the rendered desktop in dark mode, where it shows the dark still; the
    /// light one is inferred from the pair shipping side by side. A choice the
    /// user made in the wallpaper settings that pins one of the two regardless
    /// of the system appearance is not read.
    static func defaultProviderArtwork(prefersDark: Bool) -> URL {
        defaultProviderResources.appendingPathComponent(prefersDark ? "TahoeDark.heic" : "TahoeLight.heic")
    }

    static func load() -> [String: Any]? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// The provider drawing the desktop on the display identified by
    /// `displayUUID`, when every choice in the store that could apply to it
    /// names the same one; nil otherwise.
    ///
    /// Which Space is current is not something public API reveals, and the
    /// store keeps an entry for every Space it has ever seen. Rather than
    /// guess, a display counts as settled only when all of them agree, so a
    /// desktop set differently per Space never borrows another Space's
    /// wallpaper. The store-wide entries are consulted only when nothing is
    /// recorded for the display itself.
    static func desktopProvider(in store: [String: Any], displayUUID: String?) -> String? {
        let providers = Set(desktopChoices(in: store, displayUUID: displayUUID).compactMap { $0["Provider"] as? String })
        return providers.count == 1 ? providers.first : nil
    }

    /// The Aerial the store says the desktop on `displayUUID` shows, when every
    /// choice that could apply to it names the same one; nil otherwise. For a
    /// dynamic wallpaper such as the Golden Gate one this is the id of the whole
    /// set, not of any one of its light/dark, landscape/portrait videos.
    static func desktopAerialAssetID(in store: [String: Any], displayUUID: String?) -> String? {
        let ids = desktopChoices(in: store, displayUUID: displayUUID).map(aerialAssetID(of:))
        guard let first = ids.first, let id = first, ids.allSatisfy({ $0 == id }) else { return nil }
        return id
    }

    private static func desktopChoices(in store: [String: Any], displayUUID: String?) -> [[String: Any]] {
        var choices: [[String: Any]] = []
        if let displayUUID {
            let displays = store["Displays"] as? [String: Any]
            choices += desktopChoices(of: displays?[displayUUID])
            let spaces = store["Spaces"] as? [String: Any] ?? [:]
            for case let space as [String: Any] in spaces.values {
                // A Space's own entry for this display replaces its default.
                let perDisplay = (space["Displays"] as? [String: Any])?[displayUUID]
                choices += desktopChoices(of: perDisplay ?? space["Default"])
            }
        }
        if choices.isEmpty {
            choices += desktopChoices(of: store["AllSpacesAndDisplays"])
        }
        if choices.isEmpty {
            choices += desktopChoices(of: store["SystemDefault"])
        }
        return choices
    }

    private static func desktopChoices(of entry: Any?) -> [[String: Any]] {
        guard let entry = entry as? [String: Any],
              let desktop = entry["Desktop"] as? [String: Any],
              let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]] else {
            return []
        }
        return choices.filter { $0["Provider"] is String }
    }

    /// `Configuration` is a property list of its own, stored as data.
    private static func aerialAssetID(of choice: [String: Any]) -> String? {
        guard choice["Provider"] as? String == aerialsProviderIdentifier,
              let data = choice["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return configuration["assetID"] as? String
    }

    /// Every file the store names for the desktop on `displayUUID`, when all
    /// the choices that could apply to it name the same ones; empty otherwise.
    static func desktopFileURLs(in store: [String: Any], displayUUID: String?) -> [URL] {
        let sets = desktopChoices(in: store, displayUUID: displayUUID).map(fileURLs(in:))
        guard let first = sets.first, sets.allSatisfy({ $0 == first }) else { return [] }
        return first
    }

    /// Providers keep the picture they show in different places — a `Files`
    /// entry, a URL or a bookmark inside `Configuration` — and a new provider
    /// brings a new layout. Rather than know each one, every file URL found
    /// anywhere in the choice is collected, nested property lists and
    /// bookmarks included.
    private static func fileURLs(in choice: [String: Any]) -> [URL] {
        var urls: [URL] = []
        collectFileURLs(choice["Files"], into: &urls)
        collectFileURLs(choice["Configuration"], into: &urls)
        var seen: Set<URL> = []
        return urls.filter { seen.insert($0).inserted }
    }

    private static func collectFileURLs(_ value: Any?, into urls: inout [URL], depth: Int = 0) {
        guard depth < 6, let value else { return }
        switch value {
        case let string as String:
            if string.hasPrefix("file://"), let url = URL(string: string), url.isFileURL {
                urls.append(url)
            } else if string.hasPrefix("/") {
                urls.append(URL(fileURLWithPath: string))
            }
        case let dictionary as [String: Any]:
            for key in dictionary.keys.sorted() {
                collectFileURLs(dictionary[key], into: &urls, depth: depth + 1)
            }
        case let array as [Any]:
            for element in array {
                collectFileURLs(element, into: &urls, depth: depth + 1)
            }
        case let data as Data:
            if let nested = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                collectFileURLs(nested, into: &urls, depth: depth + 1)
            } else if let url = resolveBookmark(data) {
                urls.append(url)
            }
        default:
            break
        }
    }

    private static func resolveBookmark(_ data: Data) -> URL? {
        let plain: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        for options in [plain, plain.union(.withSecurityScope)] {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }
        return nil
    }

    /// A picture or movie, by its file type. A path found in a configuration
    /// can be anything, and only these can be drawn.
    static func isWallpaperMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }
}

/// The pictures the user has added in the wallpaper settings.
///
/// The store says only that the desktop shows one of them
/// ("userAddedPhotoShuffle") and names no file. They are kept as links to the
/// original files, and the wallpaper agent reads the one it draws when the
/// choice is made, so the link whose file was read most recently is the one on
/// the desktop. A choice made long ago on a volume that does not update access
/// times can be wrong; that is the limit of what the system exposes.
enum UserAddedPhotos {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.desktop.photos", isDirectory: true)
    }

    static func currentPhotoURL(in directory: URL = UserAddedPhotos.directory) -> URL? {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return nil }
        return names.sorted()
            .compactMap { name -> (url: URL, read: Date)? in
                let link = directory.appendingPathComponent(name).path
                guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link) else { return nil }
                let target = URL(fileURLWithPath: destination, relativeTo: directory).standardizedFileURL
                guard SystemWallpaperStore.isWallpaperMedia(target),
                      let read = try? target.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate else {
                    return nil
                }
                return (target, read)
            }
            .max { $0.read < $1.read }?
            .url
    }
}

/// Finds the files behind an Aerial the wallpaper store names.
///
/// The store records which Aerial the desktop shows, and the files live in the
/// wallpaper agent's own folder, not under the `SystemWallpaperURL` default
/// that outlives its target. A dynamic Aerial such as Golden Gate is one entry
/// with a light and a dark video for each of landscape and portrait, and the
/// system fetches only the ones it has needed, so the variant for this display
/// is looked for first and the others only when it has nothing on disk.
enum AerialArtwork {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
    }

    /// The `assets` of the manifest the wallpaper agent keeps next to the files.
    static func loadAssets() -> [[String: Any]]? {
        let url = directory.appendingPathComponent("manifest/entries.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return manifest["assets"] as? [[String: Any]]
    }

    /// The video of the best-matching variant that is on disk, else its
    /// thumbnail. A thumbnail is small, but the launcher blurs the picture
    /// into a few colours anyway, and it keeps the right wallpaper on screen
    /// where a video was never downloaded.
    static func artworkURL(
        assetID: String,
        assets: [[String: Any]],
        prefersDark: Bool,
        isLandscape: Bool,
        in directory: URL = AerialArtwork.directory,
        fileExists: (URL) -> Bool
    ) -> URL? {
        let wantedAppearance = prefersDark ? "dark" : "light"
        let wantedOrientation = isLandscape ? "landscape" : "portrait"
        func score(_ asset: [String: Any]) -> Int {
            let variant = asset["variant"] as? [String: Any]
            return (variant?["appearance"] as? String == wantedAppearance ? 2 : 0)
                + (variant?["orientation"] as? String == wantedOrientation ? 1 : 0)
        }
        let variants = assets
            .filter {
                $0["id"] as? String == assetID
                    || ($0["subcategories"] as? [String])?.contains(assetID) == true
            }
            .enumerated()
            .sorted { (score($0.element), -$0.offset) > (score($1.element), -$1.offset) }
            .compactMap { $0.element["id"] as? String }
        for id in variants + [assetID] {
            for url in [
                directory.appendingPathComponent("videos/\(id).mov"),
                directory.appendingPathComponent("thumbnails/\(id).png"),
            ] where fileExists(url) {
                return url
            }
        }
        return nil
    }
}

/// Provides the blurred desktop-wallpaper image `LauncherBackgroundView` uses.
///
/// The source is chosen by `WallpaperSourceResolver`: a file wherever macOS
/// exposes one, and a WindowServer wallpaper window only as a last resort. A
/// movie is sampled once at a bounded time; it is never played or retained as
/// a video layer.
@MainActor
enum WallpaperImageCache {
    private struct CacheKey: Hashable {
        let displayID: CGDirectDisplayID
        let sourceKind: WallpaperSourceKind
        let url: URL?
        let windowID: CGWindowID?
        let captureBounds: CGRect?
        let modificationDate: Date?
        let fileSize: UInt64?
        let radius: CGFloat
        /// A captured window is the same window, at the same bounds, whatever it
        /// now shows — nothing in the key notices a changed wallpaper or Space.
        /// A time bucket gives that image a short life; a file has its
        /// modification date and needs none.
        let captureEpoch: Int?
    }

    /// How long a captured wallpaper window is reused.
    private static let captureLifetime: TimeInterval = 30

    private struct Descriptor {
        let key: CacheKey
        let source: WallpaperSource
        let fallbackSources: [WallpaperSource]
    }

    private static var cache: [CacheKey: CGImage] = [:]
    private static var cacheOrder: [CacheKey] = []
    private static let cacheLimit = 8
    private static var inFlight: [CacheKey: Task<CGImage?, Never>] = [:]
    private static let maxConcurrentLoads = 2
    private static let maxVideoFrameWaitNanoseconds: UInt64 = 750_000_000

    /// Reads and blurs the wallpaper in a utility task. Only the cheap
    /// display/source metadata and bounded cache mutation run on MainActor.
    static func blurredWallpaperAsync(
        for screen: NSScreen,
        radius: CGFloat = 44
    ) async -> CGImage? {
        let descriptor = await descriptor(for: screen, radius: radius)
        if let cached = cache[descriptor.key] {
            markUsed(descriptor.key)
            return cached
        }

        if let task = inFlight[descriptor.key] {
            return await task.value
        }

        // Keep duplicate displays/radii from creating an unbounded pile of
        // Core Image contexts during a screen/settings churn.
        if inFlight.count >= maxConcurrentLoads,
           let existing = inFlight.values.first {
            _ = await existing.value
            return await blurredWallpaperAsync(for: screen, radius: radius)
        }

        let task = Task.detached(priority: .utility) {
            await Self.loadAndBlur(
                source: descriptor.source,
                fallbackSources: descriptor.fallbackSources,
                radius: radius
            )
        }
        inFlight[descriptor.key] = task
        let image = await task.value
        inFlight.removeValue(forKey: descriptor.key)
        guard let image else {
            logLoadFailure(descriptor)
            return nil
        }
        store(image, for: descriptor.key)
        return image
    }

    nonisolated private static func configuredWallpaperURL() -> URL? {
        let defaults = UserDefaults(suiteName: "com.apple.wallpaper")
        if let value = defaults?.string(forKey: "SystemWallpaperURL") {
            if let url = URL(string: value), url.isFileURL {
                return url
            }
            if value.hasPrefix("/") {
                return URL(fileURLWithPath: value)
            }
        }
        if let url = defaults?.url(forKey: "SystemWallpaperURL"), url.isFileURL {
            return url
        }
        return nil
    }

    private struct ResolvedSources {
        let source: WallpaperSource
        let fallbackSources: [WallpaperSource]
        let storeProvider: String?
        let hasScreenCaptureAccess: Bool
    }

    /// Takes the AppKit-derived inputs as parameters rather than an
    /// `NSScreen`, so the expensive part can run off the main thread: the
    /// resolver enumerates every window on the system through
    /// `CGWindowListCopyWindowInfo` (measured at 5.5ms) and then stats the
    /// resolved file. Both are thread-safe; only reading the desktop image URL
    /// and the display bounds has to happen on the caller's side.
    nonisolated private static func resolveSources(
        desktopURL: URL?,
        targetBounds: CGRect?,
        displayUUID: String?,
        prefersDarkArtwork: Bool
    ) -> ResolvedSources {
        let configuredURL = configuredWallpaperURL()
        let store = SystemWallpaperStore.load()
        let storeProvider = store.flatMap {
            SystemWallpaperStore.desktopProvider(in: $0, displayUUID: displayUUID)
        }
        let fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        let providerArtworkURL: URL?
        switch storeProvider {
        case SystemWallpaperStore.defaultProviderIdentifier, SystemWallpaperStore.systemDefaultProviderIdentifier:
            providerArtworkURL = SystemWallpaperStore.defaultProviderArtwork(prefersDark: prefersDarkArtwork)
        case SystemWallpaperStore.aerialsProviderIdentifier:
            providerArtworkURL = store
                .flatMap { SystemWallpaperStore.desktopAerialAssetID(in: $0, displayUUID: displayUUID) }
                .flatMap { assetID in
                    AerialArtwork.artworkURL(
                        assetID: assetID,
                        assets: AerialArtwork.loadAssets() ?? [],
                        prefersDark: prefersDarkArtwork,
                        isLandscape: targetBounds.map { $0.width >= $0.height } ?? true,
                        fileExists: fileExists
                    )
                }
        default:
            providerArtworkURL = nil
        }
        // Any other provider — a photo of the user's own, a built-in picture,
        // whatever macOS adds next — is read from the files its choice names.
        let storedFileURL = providerArtworkURL
            ?? store.flatMap {
                SystemWallpaperStore.desktopFileURLs(in: $0, displayUUID: displayUUID)
                    .first { SystemWallpaperStore.isWallpaperMedia($0) && fileExists($0) }
            }
            // The image provider records no file for the user's own photos.
            ?? (SystemWallpaperStore.imageProviderIdentifiers.contains(storeProvider ?? "")
                ? UserAddedPhotos.currentPhotoURL()
                : nil)
        // Files first. Listing every window on the system is the costly part of
        // resolving, so it happens only when no file names the wallpaper.
        let fileSource = WallpaperSourceResolver.resolve(
            desktopURL: desktopURL,
            configuredURL: configuredURL,
            providerArtworkURL: storedFileURL
        )
        // A preflight check only: it never prompts, and this app does not ask
        // for the permission.
        let hasScreenCaptureAccess = CGPreflightScreenCaptureAccess()
        let source = fileSource.kind != .unavailable
            ? fileSource
            : WallpaperSourceResolver.resolve(
                desktopURL: desktopURL,
                configuredURL: configuredURL,
                providerArtworkURL: storedFileURL,
                windowCandidates: wallpaperWindowCandidates(),
                targetBounds: targetBounds,
                hasScreenCaptureAccess: hasScreenCaptureAccess
            )

        // What to try when the chosen source is there but cannot be drawn — a
        // damaged picture, a file this process may not read, a movie that will
        // not decode. Existing is not the same as usable, so the other places the
        // wallpaper could come from are kept in order, each tried in turn.
        var fallbackSources: [WallpaperSource] = []
        let alternatives = [
            fileSource,
            WallpaperSourceResolver.resolve(desktopURL: nil, configuredURL: nil, providerArtworkURL: storedFileURL),
            WallpaperSourceResolver.resolve(desktopURL: nil, configuredURL: configuredURL, providerArtworkURL: nil),
        ]
        for candidate in alternatives
        where candidate.kind != .unavailable && candidate != source && !fallbackSources.contains(candidate) {
            fallbackSources.append(candidate)
        }
        return ResolvedSources(
            source: source,
            fallbackSources: fallbackSources,
            storeProvider: storeProvider,
            hasScreenCaptureAccess: hasScreenCaptureAccess
        )
    }

    /// The identifier the wallpaper store keys displays by.
    nonisolated private static func displayUUID(for displayID: CGDirectDisplayID) -> String? {
        guard displayID != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    nonisolated private static func wallpaperWindowCandidates() -> [WallpaperWindowCandidate] {
        guard let windowInfo = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windowInfo.compactMap { info in
            guard let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any] else {
                return nil
            }

            var frame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame) else {
                return nil
            }

            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            let windowName = info[kCGWindowName as String] as? String ?? ""
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let isOnscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return WallpaperWindowCandidate(
                windowID: CGWindowID(windowID),
                ownerName: ownerName,
                windowName: windowName,
                layer: layer,
                bounds: frame,
                isOnscreen: isOnscreen,
                alpha: alpha
            )
        }
    }

    private static func windowServerBounds(for screen: NSScreen) -> CGRect? {
        let displayID = (
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        )?.uint32Value
        guard let displayID, displayID != 0 else { return nil }
        let bounds = CGDisplayBounds(CGDirectDisplayID(displayID))
        return bounds.width > 1 && bounds.height > 1 ? bounds : nil
    }

    private static func descriptor(for screen: NSScreen, radius: CGFloat) async -> Descriptor {
        let displayID = (
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        )?.uint32Value ?? 0
        let desktopURL = NSWorkspace.shared.desktopImageURL(for: screen)
        let targetBounds = windowServerBounds(for: screen)
        let storeDisplayUUID = displayUUID(for: displayID)
        let prefersDarkArtwork = NSApplication.shared.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let resolution = await Task.detached(priority: .userInitiated) {
            let resolved = resolveSources(
                desktopURL: desktopURL,
                targetBounds: targetBounds,
                displayUUID: storeDisplayUUID,
                prefersDarkArtwork: prefersDarkArtwork
            )
            let attributes = resolved.source.url.flatMap {
                try? FileManager.default.attributesOfItem(atPath: $0.path)
            }
            return (
                resolved: resolved,
                modificationDate: attributes?[.modificationDate] as? Date,
                fileSize: (attributes?[.size] as? NSNumber)?.uint64Value
            )
        }.value
        let resolved = resolution.resolved
        let source = resolved.source
        let modificationDate = resolution.modificationDate
        let fileSize = resolution.fileSize
        let key = CacheKey(
            displayID: displayID,
            sourceKind: source.kind,
            url: source.url,
            windowID: source.windowID,
            captureBounds: source.captureBounds,
            modificationDate: modificationDate,
            fileSize: fileSize,
            radius: radius,
            captureEpoch: source.kind == .windowCapture
                ? Int(Date().timeIntervalSince1970 / captureLifetime)
                : nil
        )
        DiagnosticsLog.launcher.info(
            "wallpaper descriptor: sourceKind=\(source.kind.rawValue, privacy: .public), displayID=\(displayID, privacy: .public), windowID=\(source.windowID ?? 0, privacy: .public), storeProvider=\(resolved.storeProvider ?? "<none>", privacy: .public), captureAccess=\(resolved.hasScreenCaptureAccess, privacy: .public), resolvedURL=\(source.url?.path ?? "<unavailable>", privacy: .private), radius=\(radius, privacy: .public), cacheHit=\(cache[key] != nil, privacy: .public)"
        )
        return Descriptor(
            key: key,
            source: source,
            fallbackSources: resolved.fallbackSources
        )
    }

    private static func logLoadFailure(_ descriptor: Descriptor) {
        DiagnosticsLog.launcher.error(
            "wallpaper load failed: sourceKind=\(descriptor.source.kind.rawValue, privacy: .public), displayID=\(descriptor.key.displayID, privacy: .public), windowID=\(descriptor.source.windowID ?? 0, privacy: .public), resolvedURL=\(descriptor.source.url?.path ?? "<unavailable>", privacy: .private), radius=\(descriptor.key.radius, privacy: .public)"
        )
    }

    private static func markUsed(_ key: CacheKey) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    private static func store(_ image: CGImage, for key: CacheKey) {
        cache[key] = image
        markUsed(key)
        while cacheOrder.count > cacheLimit {
            let evictedKey = cacheOrder.removeFirst()
            cache.removeValue(forKey: evictedKey)
        }
    }

    /// Releases every cached blurred wallpaper. These are full-screen-derived
    /// images held in `static` storage, so without this they lived for the
    /// whole process — a resident launcher that the user opened once kept them
    /// for the rest of the session. Called on the same idle timer that releases
    /// the icon memory cache; the next open re-blurs from the wallpaper file.
    static func evictAll() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    /// The first of `source` and then `fallbackSources` that can actually be
    /// drawn, blurred.
    nonisolated static func loadAndBlur(
        source: WallpaperSource,
        fallbackSources: [WallpaperSource],
        radius: CGFloat
    ) async -> CGImage? {
        // Blurred, the picture's detail is gone anyway, so a small one is enough.
        // With the blur off the user asked for the picture itself, which a
        // 960-pixel copy stretched over a large display is not.
        let maxDimension = radius > 0 ? blurInputMaxDimension : sharpMaxDimension
        for candidate in [source] + fallbackSources {
            if let image = await loadSourceImage(candidate, maxDimension: maxDimension) {
                return blur(image, radius: radius, maxDimension: maxDimension)
            }
        }
        return nil
    }

    nonisolated static func loadSourceImage(
        _ source: WallpaperSource,
        maxDimension: CGFloat = blurInputMaxDimension
    ) async -> CIImage? {
        switch source.kind {
        case .windowCapture:
            guard let windowID = source.windowID,
                  let captured = captureWallpaperWindow(
                      windowID: windowID,
                      bounds: source.captureBounds
                  ) else {
                return nil
            }
            return CIImage(cgImage: captured)
        case .staticImage:
            guard let url = source.url,
                  let image = decodeDownsampled(url, maxPixelSize: maxDimension) else {
                return nil
            }
            return CIImage(cgImage: image)
        case .aerialVideo:
            guard let url = source.url,
                  let frame = await videoFrame(from: url) else {
                return nil
            }
            return CIImage(cgImage: frame)
        case .unavailable:
            return nil
        }
    }

    /// WindowServer's public capture API must remain inside the detached
    /// utility task. If Screen Recording permission is missing it returns nil,
    /// allowing `loadAndBlur` to use its explicit file/Aerial fallback.
    nonisolated private static func captureWallpaperWindow(
        windowID: CGWindowID,
        bounds: CGRect?
    ) -> CGImage? {
        // The public symbol is marked unavailable by the macOS 15 SDK even
        // though WindowServer still exports it and it remains the only
        // per-window snapshot API needed here. Resolve it dynamically so the
        // build keeps the macOS 15 deployment target while retaining the
        // documented runtime permission behavior.
        typealias CreateImage = @convention(c) (
            CGRect,
            CGWindowListOption,
            CGWindowID,
            CGWindowImageOption
        ) -> CGImage?
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(defaultHandle, "CGWindowListCreateImage") else {
            return nil
        }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow = CGWindowListOption(rawValue: 1 << 3)
        let imageOptions = CGWindowImageOption(rawValue: (1 << 0) | (1 << 3))
        return createImage(
            bounds ?? .null,
            includingWindow,
            windowID,
            imageOptions
        )
    }

    /// Extract exactly one frame. The timeout task bounds how long a stale
    /// wallpaper request can occupy a utility slot; cancellation asks
    /// AVFoundation to stop generation rather than leaving a movie running.
    nonisolated private static func videoFrame(from url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)

        // The deadline starts before the duration is read, not after: on a slow
        // volume or a damaged movie that read is where the time goes, and
        // while it ran nothing bounded it — the request held one of the two
        // load slots, and every later wallpaper request waited behind it.
        return await withTaskGroup(of: CGImage?.self) { group in
            group.addTask {
                let duration: CMTime
                do {
                    duration = try await asset.load(.duration)
                } catch {
                    duration = .zero
                }
                let durationSeconds = duration.isNumeric ? duration.seconds : 0
                let sampleSeconds = durationSeconds.isFinite && durationSeconds > 0
                    ? min(durationSeconds * 0.5, 1.0)
                    : 0
                let time = CMTime(seconds: sampleSeconds, preferredTimescale: 600)
                return await extractVideoFrame(asset: asset, at: time)
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: maxVideoFrameWaitNanoseconds)
                } catch {
                    return nil
                }
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    nonisolated private static func extractVideoFrame(
        asset: AVAsset,
        at time: CMTime
    ) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_920, height: 1_920)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        return await withTaskCancellationHandler(operation: { () async -> CGImage? in
            if Task.isCancelled {
                generator.cancelAllCGImageGeneration()
                return nil
            }
            do {
                let result = try await generator.image(at: time)
                return result.image
            } catch {
                return nil
            }
        }, onCancel: {
            generator.cancelAllCGImageGeneration()
        })
    }

    /// The size everything is drawn at before the blur, on the longer side. The
    /// result is blurred and stretched over the whole screen, so more pixels
    /// would only make the blur slower.
    nonisolated static let blurInputMaxDimension: CGFloat = 960

    /// The longer side an unblurred wallpaper keeps: a 4K display's worth, about
    /// 33MB as pixels, instead of the blur's 960.
    nonisolated static let sharpMaxDimension: CGFloat = 3_840

    /// Decodes an image file at no more than `maxPixelSize` on its longer side.
    ///
    /// `CIImage(contentsOf:)` decoded the whole file only for the blur to shrink
    /// it: the default macOS 27 wallpaper is a 6016x6016 HEIC, which cost about
    /// 170MB at peak and half a second that way, against 45MB and a quarter of
    /// a second decoding straight to the size the blur uses. ImageIO also
    /// applies the file's orientation, which `CIImage(contentsOf:)` ignored, and
    /// takes the image a HEIF file marks as its primary one.
    nonisolated static func decodeDownsampled(_ url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            CGImageSourceGetPrimaryImageIndex(source),
            options as CFDictionary
        )
    }

    nonisolated private static func blur(_ image: CIImage, radius: CGFloat, maxDimension: CGFloat) -> CGImage? {
        // Downsample to a fixed max dimension before the expensive blur. With no
        // blur nothing is enlarged: the picture is shown as it is.
        let extent = image.extent
        let fitScale = maxDimension / max(extent.width, extent.height, 1)
        let scale = radius > 0 ? fitScale : min(fitScale, 1)
        let downsampled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Gaussian blur samples outside the source extent. Clamp first so
        // those samples repeat edge pixels rather than transparent bands.
        let clamped = downsampled.clampedToExtent()

        let colorFilter = CIFilter.colorControls()
        if radius > 0 {
            let blurFilter = CIFilter.gaussianBlur()
            blurFilter.inputImage = clamped
            blurFilter.radius = Float(radius)
            colorFilter.inputImage = blurFilter.outputImage
        } else {
            colorFilter.inputImage = downsampled
        }
        // The blurred look is nudged toward richer colour; the picture itself is not.
        colorFilter.saturation = radius > 0 ? 1.15 : 1.0

        guard let output = colorFilter.outputImage else { return nil }
        let cropped = output.cropped(to: downsampled.extent)
        // The picture itself is rendered into sRGB explicitly: left to the context's
        // default its colours came out lighter than the file's.
        if radius <= 0, let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            return Self.renderContext.createCGImage(cropped, from: cropped.extent, format: .RGBA8, colorSpace: srgb)
        }
        return Self.renderContext.createCGImage(cropped, from: cropped.extent)
    }

    /// `CIContext` is expensive to create and is designed to be kept alive and
    /// reused — each instance sets up its own GPU command queue and
    /// intermediate buffers. This used to be constructed per blur, so every
    /// cache miss (display change, wallpaper change, material slider drag) paid
    /// that setup again. `cacheIntermediates: false` keeps the shared instance
    /// from accumulating intermediate buffers between the infrequent,
    /// full-screen-sized renders this does.
    ///
    /// `nonisolated` because the blur runs off the main actor while this type
    /// is `@MainActor`. Sharing one context across those threads is what Apple
    /// documents ("you can use a single CIContext object from multiple
    /// threads"), and `CIContext` is `Sendable`, so no `unsafe` opt-out is
    /// needed to say so.
    private nonisolated static let renderContext = CIContext(options: [.cacheIntermediates: false])
}
