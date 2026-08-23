import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Diagnostics
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
/// WindowServer wallpaper windows are preferred by the runtime overload below
/// because `NSWorkspace` may expose `DefaultDesktop.heic` while the rendered
/// desktop is supplied by Dock. The file-backed path remains available as an
/// explicit fallback when window capture is unavailable.
enum WallpaperSourceResolver {
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    private static let wallpaperLayerThreshold = -2_000_000_000

    static func resolve(desktopURL: URL?, configuredURL: URL?) -> WallpaperSource {
        resolve(
            desktopURL: desktopURL,
            configuredURL: configuredURL,
            isUsableFile: isUsableFile
        )
    }

    /// The injected file predicate keeps source selection testable without a
    /// live `NSScreen` or a user's wallpaper files.
    static func resolve(
        desktopURL: URL?,
        configuredURL: URL?,
        isUsableFile: (URL) -> Bool
    ) -> WallpaperSource {
        if let desktopURL,
           isUsableFile(desktopURL),
           !isDefaultDesktopURL(desktopURL) {
            return source(for: desktopURL)
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
        windowCandidates: [WallpaperWindowCandidate],
        targetBounds: CGRect?,
        isUsableFile: (URL) -> Bool
    ) -> WallpaperSource {
        let fileSource = resolve(
            desktopURL: desktopURL,
            configuredURL: configuredURL,
            isUsableFile: isUsableFile
        )
        guard fileSource.kind == .unavailable else { return fileSource }

        if let candidate = selectWallpaperWindow(
            candidates: windowCandidates,
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
        windowCandidates: [WallpaperWindowCandidate],
        targetBounds: CGRect?
    ) -> WallpaperSource {
        resolve(
            desktopURL: desktopURL,
            configuredURL: configuredURL,
            windowCandidates: windowCandidates,
            targetBounds: targetBounds,
            isUsableFile: isUsableFile
        )
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

/// Provides the blurred desktop-wallpaper image `LauncherBackgroundView` uses.
///
/// The source is resolved from the display's WindowServer wallpaper window
/// first, then from the normal workspace image and read-only
/// `com.apple.wallpaper` Aerial setting. A movie is sampled once at a bounded
/// time; it is never played or retained as a video layer.
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

    /// Returns the source selected for a screen without loading or decoding it.
    static func source(for screen: NSScreen) -> WallpaperSource {
        resolveSources(for: screen).source
    }

    /// Reads and blurs the wallpaper in a utility task. Only the cheap
    /// display/source metadata and bounded cache mutation run on MainActor.
    static func blurredWallpaperAsync(
        for screen: NSScreen,
        radius: CGFloat = 44
    ) async -> CGImage? {
        let descriptor = descriptor(for: screen, radius: radius)
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

    private static func configuredWallpaperURL() -> URL? {
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
    }

    private static func resolveSources(for screen: NSScreen) -> ResolvedSources {
        let desktopURL = NSWorkspace.shared.desktopImageURL(for: screen)
        let configuredURL = configuredWallpaperURL()
        let source = WallpaperSourceResolver.resolve(
            desktopURL: desktopURL,
            configuredURL: configuredURL,
            windowCandidates: wallpaperWindowCandidates(),
            targetBounds: windowServerBounds(for: screen)
        )
        let fallbackSource: WallpaperSource?
        if source.kind == .windowCapture {
            // A WindowServer image can be unavailable when Screen Recording
            // permission is denied. Keep the old file/Aerial path explicit so
            // the utility task can try it without touching AppKit again.
            fallbackSource = WallpaperSourceResolver.resolve(
                desktopURL: desktopURL,
                configuredURL: configuredURL
            )
        } else {
            fallbackSource = nil
        }
        return ResolvedSources(source: source, fallbackSource: fallbackSource)
    }

    private static func wallpaperWindowCandidates() -> [WallpaperWindowCandidate] {
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

    private static func descriptor(for screen: NSScreen, radius: CGFloat) -> Descriptor {
        let displayID = (
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        )?.uint32Value ?? 0
        let resolved = resolveSources(for: screen)
        let source = resolved.source
        let fileAttributes = source.url.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)
        }
        let modificationDate = fileAttributes?[.modificationDate] as? Date
        let fileSize = (fileAttributes?[.size] as? NSNumber)?.uint64Value
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
            "wallpaper descriptor: sourceKind=\(source.kind.rawValue, privacy: .public), displayID=\(displayID, privacy: .public), windowID=\(source.windowID ?? 0, privacy: .public), resolvedURL=\(source.url?.path ?? "<unavailable>", privacy: .private), radius=\(radius, privacy: .public), cacheHit=\(cache[key] != nil, privacy: .public)"
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

    nonisolated private static func loadSourceImage(
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
            guard let url = source.url else { return nil }
            return CIImage(contentsOf: url)
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

    nonisolated private static func blur(_ image: CIImage, radius: CGFloat) -> CGImage? {
        // Downsample to a fixed max dimension before the expensive blur.
        let maxDimension: CGFloat = 960
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
