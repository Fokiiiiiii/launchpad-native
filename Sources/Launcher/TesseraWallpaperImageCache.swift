import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Diagnostics

/// Provides the blurred desktop-wallpaper image `TesseraBackgroundView` uses
/// as its background layer — matching the "Tessera" design reference's own
/// intent (its SwiftUI `WallpaperPlaceholder` doc comment explicitly says the
/// real implementation should substitute `NSWorkspace`'s current wallpaper
/// image) and real Launchpad/Mission Control's own behavior (a blurred view
/// of the user's actual desktop, not a synthetic placeholder).
///
/// Deliberately does NOT use a screen-capture API (`CGWindowListCreateImage`/
/// ScreenCaptureKit) — that would require Screen Recording permission, a
/// brand-new privacy prompt this app has never needed for anything else, just
/// for a decorative background. `NSWorkspace.desktopImageURL(for:)` needs no
/// entitlement (this project has no `.entitlements` file at all — an
/// unsigned, unsandboxed SPM-built `.app`) and directly reflects the same
/// wallpaper the user actually sees.
@MainActor
enum TesseraWallpaperImageCache {
    private struct CacheKey: Hashable {
        let displayID: CGDirectDisplayID
        let url: URL?
    }

    private static var cache: [CacheKey: CGImage] = [:]
    private static let context = CIContext()

    /// Returns a blurred, desaturation-corrected `CGImage` suitable for a
    /// full-screen decorative background layer. Downsamples before blurring
    /// (a large Gaussian blur at native 5K resolution is expensive and
    /// pointless — the result is scaled up and further dimmed by the scrim/
    /// material layers on top anyway) and memoizes per (screen, wallpaper
    /// URL) so the blur only ever runs once per screen even though both the
    /// main launcher window and `MenuBarCoverWindow` pull from this cache.
    static func blurredWallpaper(for screen: NSScreen) -> CGImage? {
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        let key = CacheKey(displayID: displayID, url: url)
        if let cached = cache[key] {
            return cached
        }

        let sourceImage: CIImage
        let usedFallback: Bool
        if let url, let loaded = CIImage(contentsOf: url) {
            sourceImage = loaded
            usedFallback = false
        } else {
            sourceImage = fallbackGradientImage(size: screen.frame.size)
            usedFallback = true
        }

        guard let blurred = blur(sourceImage) else {
            if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_TESSERA_BACKGROUND"] == "1" {
                DiagnosticsLog.launcher.info("TesseraWallpaperImageCache: blur failed for url=\(url?.path ?? "nil", privacy: .public)")
            }
            return nil
        }
        cache[key] = blurred
        if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_TESSERA_BACKGROUND"] == "1" {
            DiagnosticsLog.launcher.info("TesseraWallpaperImageCache: loaded url=\(url?.path ?? "nil", privacy: .public), usedFallback=\(usedFallback, privacy: .public), screen.frame=\(NSStringFromRect(screen.frame), privacy: .public)")
        }
        return blurred
    }

    private static func blur(_ image: CIImage) -> CGImage? {
        // Downsample to a fixed max dimension before the (expensive)
        // Gaussian blur — standard Core Image practice for a background
        // that will be displayed heavily blurred/dimmed regardless.
        let maxDimension: CGFloat = 960
        let extent = image.extent
        let scale = maxDimension / max(extent.width, extent.height, 1)
        let downsampled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = downsampled
        blurFilter.radius = 44 // scaled down proportionally from the reference's 60-70pt at full resolution

        let colorFilter = CIFilter.colorControls()
        colorFilter.inputImage = blurFilter.outputImage
        colorFilter.saturation = 1.15

        guard let output = colorFilter.outputImage else { return nil }
        // Crop back to the (scaled) source extent — Gaussian blur expands
        // the extent infinitely, which `CIContext.createCGImage` needs a
        // finite rect for.
        let cropped = output.cropped(to: downsampled.extent)
        return context.createCGImage(cropped, from: cropped.extent)
    }

    /// Used only if `desktopImageURL` is unavailable or fails to load —
    /// a soft two-tone gradient in the same spirit as the reference's own
    /// `WallpaperPlaceholder`, run through the identical blur/saturate
    /// pipeline so the rest of `TesseraBackgroundView` treats it no
    /// differently than a real wallpaper.
    private static func fallbackGradientImage(size: CGSize) -> CIImage {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: size.height)
        gradient.point1 = CGPoint(x: size.width, y: 0)
        gradient.color0 = CIColor(red: 0.17, green: 0.38, blue: 0.66, alpha: 1)
        gradient.color1 = CIColor(red: 0.08, green: 0.06, blue: 0.10, alpha: 1)
        let rect = CGRect(origin: .zero, size: size)
        return (gradient.outputImage ?? CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.11))).cropped(to: rect)
    }
}
