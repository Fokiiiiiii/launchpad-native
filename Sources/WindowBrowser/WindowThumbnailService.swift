import AppKit
import Diagnostics
// SCShareableContent is not Sendable, but it is only ever read once fetched.
@preconcurrency import ScreenCaptureKit

/// Captures a single-shot thumbnail for one window via the public
/// `SCScreenshotManager.captureImage` (macOS 14+) — verified live on this
/// machine. Cached briefly and only for windows actually requested (the
/// window browser UI only asks for the currently-visible cells' thumbnails,
/// never a background sweep of every window on the system), matching "全ウ
/// インドウの常時再capture禁止."
public actor WindowThumbnailService {
    private struct CacheEntry {
        let image: NSImage
        let capturedAt: ContinuousClock.Instant
    }

    private var cache: [Int: CacheEntry] = [:]
    private let ttl: Duration
    /// Largest pixel extent a cached thumbnail is captured at. The browser's
    /// cells are 140x130pt, so this covers 2x backing scale with headroom.
    private static let maxThumbnailPixelExtent: CGFloat = 320

    /// Bumped by `evictAll`. A capture that began before it must not put its result
    /// back: the browser it was for has already gone away.
    private var generation = 0
    private var inFlight: [Int: Task<NSImage?, Never>] = [:]
    /// One listing of the on-screen windows, shared by every capture asking while
    /// it is being fetched — a page of cells shows up all at once, and each used
    /// to enumerate every window on the system by itself.
    private var contentTask: Task<SCShareableContent, Error>?
    /// Test seam: stands in for the ScreenCaptureKit capture.
    private let captureOverride: (@Sendable (WindowInfo) async -> NSImage?)?

    public init(ttl: Duration = .seconds(2)) {
        self.ttl = ttl
        self.captureOverride = nil
    }

    init(ttl: Duration = .seconds(2), capture: @escaping @Sendable (WindowInfo) async -> NSImage?) {
        self.ttl = ttl
        self.captureOverride = capture
    }

    public func thumbnail(for window: WindowInfo) async -> NSImage? {
        let now = ContinuousClock.now
        if let entry = cache[window.id], now - entry.capturedAt < ttl {
            return entry.image
        }
        // Drop everything already past its TTL rather than only overwriting
        // the key being requested: a window that is never asked about again
        // (closed app, dismissed browser) would otherwise keep its image for
        // the process's lifetime.
        cache = cache.filter { now - $0.value.capturedAt < ttl }

        if let running = inFlight[window.id] { return await running.value }
        let startedIn = generation
        let task = Task { await self.capture(window, startedIn: startedIn, at: now) }
        inFlight[window.id] = task
        let image = await task.value
        if generation == startedIn { inFlight[window.id] = nil }
        return image
    }

    private func capture(_ window: WindowInfo, startedIn: Int, at now: ContinuousClock.Instant) async -> NSImage? {
        let captured: NSImage?
        if let captureOverride { captured = await captureOverride(window) } else { captured = await captureWindow(window) }
        guard let image = captured else { return nil }
        if generation == startedIn { cache[window.id] = CacheEntry(image: image, capturedAt: now) }
        return image
    }

    private func shareableContent() async throws -> SCShareableContent {
        if let running = contentTask { return try await running.value }
        let task = Task { try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        contentTask = task
        defer { contentTask = nil }
        return try await task.value
    }

    private func captureWindow(_ window: WindowInfo) async -> NSImage? {
        do {
            let content = try await shareableContent()
            guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            // Capture at display size, not the window's native pixel size.
            // These land in 140x130pt cells, so a full-resolution grab of a
            // 1920x1080 window was ~8 MB of RGBA held per window purely to be
            // downscaled at draw time. Aspect ratio is preserved so the cell's
            // own scaling still gets an undistorted image.
            let nativeWidth = max(scWindow.frame.width, 1)
            let nativeHeight = max(scWindow.frame.height, 1)
            let downscale = min(1.0, Self.maxThumbnailPixelExtent / max(nativeWidth, nativeHeight))
            config.width = max(Int(nativeWidth * downscale), 1)
            config.height = max(Int(nativeHeight * downscale), 1)
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            DiagnosticsLog.catalog.error("Window thumbnail capture failed for window \(window.id, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func evictAll() {
        generation += 1
        cache.removeAll()
        inFlight.removeAll()
    }
}
