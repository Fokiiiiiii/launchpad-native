import AppKit
@preconcurrency import AVFoundation
import ColorSync
import CoreImage
import CoreImage.CIFilterBuiltins
import Diagnostics
import ImageIO
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
            return WallpaperSource(kind: .staticImage, url: providerArtworkURL)
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
        var providers: Set<String> = []
        if let displayUUID {
            let displays = store["Displays"] as? [String: Any]
            providers.formUnion(desktopProviders(of: displays?[displayUUID]))
            let spaces = store["Spaces"] as? [String: Any] ?? [:]
            for case let space as [String: Any] in spaces.values {
                // A Space's own entry for this display replaces its default.
                let perDisplay = (space["Displays"] as? [String: Any])?[displayUUID]
                providers.formUnion(desktopProviders(of: perDisplay ?? space["Default"]))
            }
        }
        if providers.isEmpty {
            providers.formUnion(desktopProviders(of: store["AllSpacesAndDisplays"]))
        }
        if providers.isEmpty {
            providers.formUnion(desktopProviders(of: store["SystemDefault"]))
        }
        return providers.count == 1 ? providers.first : nil
    }

    private static func desktopProviders(of entry: Any?) -> [String] {
        guard let entry = entry as? [String: Any],
              let desktop = entry["Desktop"] as? [String: Any],
              let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]] else {
            return []
        }
        return choices.compactMap { $0["Provider"] as? String }
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
    }

    private struct Descriptor {
        let key: CacheKey
        let source: WallpaperSource
        let fallbackSource: WallpaperSource?
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
                fallbackSource: descriptor.fallbackSource,
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
        let fallbackSource: WallpaperSource?
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
        let storeProvider = SystemWallpaperStore.load().flatMap {
            SystemWallpaperStore.desktopProvider(in: $0, displayUUID: displayUUID)
        }
        let providerArtworkURL = storeProvider == SystemWallpaperStore.defaultProviderIdentifier
            ? SystemWallpaperStore.defaultProviderArtwork(prefersDark: prefersDarkArtwork)
            : nil
        // A preflight check only: it never prompts, and this app does not ask
        // for the permission.
        let hasScreenCaptureAccess = CGPreflightScreenCaptureAccess()
        let source = WallpaperSourceResolver.resolve(
            desktopURL: desktopURL,
            configuredURL: configuredURL,
            providerArtworkURL: providerArtworkURL,
            windowCandidates: wallpaperWindowCandidates(),
            targetBounds: targetBounds,
            hasScreenCaptureAccess: hasScreenCaptureAccess
        )
        let fallbackSource: WallpaperSource?
        if source.kind == .windowCapture {
            // A WindowServer image can be unavailable when Screen Recording
            // permission is denied. Keep the old file/Aerial path explicit so
            // the utility task can try it without touching AppKit again.
            fallbackSource = WallpaperSourceResolver.resolve(
                desktopURL: desktopURL,
                configuredURL: configuredURL,
                providerArtworkURL: providerArtworkURL
            )
        } else {
            fallbackSource = nil
        }
        return ResolvedSources(
            source: source,
            fallbackSource: fallbackSource,
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
            radius: radius
        )
        DiagnosticsLog.launcher.info(
            "wallpaper descriptor: sourceKind=\(source.kind.rawValue, privacy: .public), displayID=\(displayID, privacy: .public), windowID=\(source.windowID ?? 0, privacy: .public), storeProvider=\(resolved.storeProvider ?? "<none>", privacy: .public), captureAccess=\(resolved.hasScreenCaptureAccess, privacy: .public), resolvedURL=\(source.url?.path ?? "<unavailable>", privacy: .private), radius=\(radius, privacy: .public), cacheHit=\(cache[key] != nil, privacy: .public)"
        )
        return Descriptor(
            key: key,
            source: source,
            fallbackSource: resolved.fallbackSource
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

    nonisolated private static func loadAndBlur(
        source: WallpaperSource,
        fallbackSource: WallpaperSource?,
        radius: CGFloat
    ) async -> CGImage? {
        if let image = await loadSourceImage(source) {
            return blur(image, radius: radius)
        }

        guard source.kind == .windowCapture,
              let fallbackSource,
              let fallbackImage = await loadSourceImage(fallbackSource) else {
            return nil
        }
        return blur(fallbackImage, radius: radius)
    }

    nonisolated static func loadSourceImage(
        _ source: WallpaperSource
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
                  let image = decodeDownsampled(url, maxPixelSize: blurInputMaxDimension) else {
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

        return await withTaskGroup(of: CGImage?.self) { group in
            group.addTask {
                await extractVideoFrame(asset: asset, at: time)
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

    nonisolated private static func blur(_ image: CIImage, radius: CGFloat) -> CGImage? {
        // Downsample to a fixed max dimension before the expensive blur.
        let maxDimension = blurInputMaxDimension
        let extent = image.extent
        let scale = maxDimension / max(extent.width, extent.height, 1)
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
        colorFilter.saturation = 1.15

        guard let output = colorFilter.outputImage else { return nil }
        let cropped = output.cropped(to: downsampled.extent)
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
