import AppKit
import Diagnostics
import ImageIO
import Persistence

/// Applies `AppIconStyle` to the running process (`NSApp.applicationIconImage`,
/// which resets on every relaunch, so `AppDelegate` calls `apply(_:)` at launch)
/// and to the bundle's Finder icon (see `applyToBundle`). The bundle's own
/// Info.plist and .icns are never touched: changing them would need re-signing.
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
    /// makes a picker icon about 25KB and the 256pt process icon about 1MB,
    /// each read once. At most four styles at three sizes are ever kept.
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
        app.applicationIconImage = image(for: style, pointSize: applicationIconPointSize).flatMap(paddedForIconGrid)
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("AppIconVariants") else { return }
        applyToBundle(style, bundleURL: Bundle.main.bundleURL, variants: directory, defaults: .standard)
    }

    /// How much of the canvas an icon's shape fills. Apple's icon grid is 824 of
    /// 1024 points, which leaves the margin every other icon in the Dock and
    /// Finder has. The variants are drawn edge to edge for the picker, so used
    /// as they were they came out about a quarter larger than their neighbours.
    static let iconGridFraction: CGFloat = 824.0 / 1024.0

    /// `image` shrunk onto a transparent canvas of the same size, at the icon grid.
    static func paddedForIconGrid(_ image: NSImage) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let width = CGFloat(source.width), height = CGFloat(source.height)
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(
            x: width * (1 - iconGridFraction) / 2, y: height * (1 - iconGridFraction) / 2,
            width: width * iconGridFraction, height: height * iconGridFraction
        ))
        guard let padded = context.makeImage() else { return nil }
        return NSImage(cgImage: padded, size: image.size)
    }

    private static let appliedBundleStyleKey = "AppliedBundleIconStyle"
    /// Bumped when the picture drawn for the bundle changes, so an icon written
    /// by an older version is written again.
    private static let bundleIconRendering = 2

    /// Dock, Finder and Spotlight draw the bundle's icon, not the process's, and
    /// this app has no Dock tile of its own, so a style set only on the process
    /// showed nowhere. It is also set on the bundle the way Finder's Get Info
    /// does: an `Icon\r` file the code signature leaves out, so the CDHash, and
    /// the permissions granted to it, stay as they are. Every style, `classic`
    /// included, is written at the icon grid: the bundle's own `AppIcon.icns` is
    /// drawn edge to edge too. Written only when the style or the rendering
    /// changes, and skipped for a host without the variants (tests).
    static func applyToBundle(_ style: AppIconStyle, bundleURL: URL, variants: URL, defaults: UserDefaults) {
        guard FileManager.default.fileExists(atPath: variants.path) else { return }
        let bundlePath = bundleURL.path
        let marker = "\(style.rawValue)#\(bundleIconRendering)"
        let hasCustomIcon = FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("Icon\r").path)
        guard !hasCustomIcon || defaults.string(forKey: appliedBundleStyleKey) != marker else { return }
        guard let picture = NSImage(contentsOf: variants.appendingPathComponent("\(style.rawValue).png")),
              let icon = paddedForIconGrid(picture),
              NSWorkspace.shared.setIcon(icon, forFile: bundlePath, options: [])
        else {
            DiagnosticsLog.settings.error("Could not set the \(style.rawValue, privacy: .public) icon on the app bundle")
            return
        }
        defaults.set(marker, forKey: appliedBundleStyleKey)
        NSWorkspace.shared.noteFileSystemChanged(bundlePath)
    }
}
