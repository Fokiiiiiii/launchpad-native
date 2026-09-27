import AppKit
import ImageIO
import Persistence

/// Applies `AppIconStyle` to the *running* process's Dock/App-Switcher
/// representation via `NSApp.applicationIconImage` — this never touches the
/// on-disk bundle's Info.plist/.icns (impossible without re-signing an
/// unsigned build); it only affects this process's lifetime, and resets to
/// the bundle default on every relaunch, so `AppDelegate` must also call
/// `apply(_:)` once at launch time.
@MainActor
public enum AppIconStyleApplier {
    /// The icon for `style`, decoded at the size it is drawn at.
    ///
    /// The variants ship at 1024px, but everywhere this app shows one is
    /// small: 40pt in the style picker, 76pt on the About tab, 64pt in an
    /// alert, 18pt in the menu bar. Reading the file whole cost 4MB per
    /// variant, which stayed in memory for as long as the process lived once
    /// Settings had been opened, and the picker read all four again from disk
    /// on every redraw. Decoding at the drawn size and keeping the result
    /// makes each one a few dozen kilobytes, read once.
    public static func image(for style: AppIconStyle, pointSize: CGFloat) -> NSImage? {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("AppIconVariants") else {
            return nil
        }
        return image(for: style, pointSize: pointSize, in: directory)
    }

    static func image(for style: AppIconStyle, pointSize: CGFloat, in directory: URL) -> NSImage? {
        let url = directory.appendingPathComponent("\(style.rawValue).png")
        let pixelSize = Int((pointSize * backingScale).rounded(.up))
        let key = CacheKey(url: url, pixelSize: pixelSize)
        if let cached = cache[key] {
            return cached
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(
            cgImage: decoded,
            size: NSSize(width: CGFloat(decoded.width) / backingScale, height: CGFloat(decoded.height) / backingScale)
        )
        cache[key] = image
        return image
    }

    /// Retina, the densest scale a Mac display has.
    private static let backingScale: CGFloat = 2

    /// Alerts draw the process icon at 64pt and the menu-bar item at 18pt.
    static let applicationIconPointSize: CGFloat = 256

    private struct CacheKey: Hashable {
        let url: URL
        let pixelSize: Int
    }

    private static var cache: [CacheKey: NSImage] = [:]

    public static func apply(_ style: AppIconStyle) {
        // `NSApp` is an implicitly-unwrapped optional that stays nil until the
        // application object exists — before `NSApplication.shared` is first
        // touched, and in any host that never creates one. Force-unwrapping it
        // here crashed outright the first time this was called outside a
        // running app. There is also nothing to apply in that case: the icon
        // being set is the *process's* Dock representation, which only means
        // anything once there is a process showing one.
        guard let app = NSApp else { return }
        // nil falls back to the bundle's own .icns
        app.applicationIconImage = image(for: style, pointSize: applicationIconPointSize)
    }
}
