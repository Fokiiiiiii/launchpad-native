import AppKit
import Diagnostics
import ScreenCaptureKit

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

    public init(ttl: Duration = .seconds(2)) {
        self.ttl = ttl
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

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
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
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            cache[window.id] = CacheEntry(image: image, capturedAt: now)
            return image
        } catch {
            DiagnosticsLog.catalog.error("Window thumbnail capture failed for window \(window.id, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func evictAll() {
        cache.removeAll()
    }
}
