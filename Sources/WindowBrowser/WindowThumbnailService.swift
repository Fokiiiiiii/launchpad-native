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

    public init(ttl: Duration = .seconds(2)) {
        self.ttl = ttl
    }

    public func thumbnail(for window: WindowInfo) async -> NSImage? {
        let now = ContinuousClock.now
        if let entry = cache[window.id], now - entry.capturedAt < ttl {
            return entry.image
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = max(Int(scWindow.frame.width), 1)
            config.height = max(Int(scWindow.frame.height), 1)
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
