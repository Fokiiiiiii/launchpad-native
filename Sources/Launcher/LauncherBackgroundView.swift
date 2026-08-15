import AppKit
import Diagnostics
import Persistence
import QuartzCore

/// Full-screen decorative background matching the design
/// reference's own `TSBackground` composition (the reference's
/// `.glass` mode / the reference mockup's Stage layer stack): a base fill, a
/// blurred wallpaper layer, a dark scrim, a soft "material sheen" highlight,
/// and (main window only) two ambient light blooms.
///
/// Deliberately built from plain `CALayer`/`CAGradientLayer` sublayers —
/// **not** `NSGlassEffectView`/`NSVisualEffectView`. The reference itself
/// never uses a glass/blur *material* for its full-screen background (that's
/// reserved exclusively for small chip/card UI — the search pill, the folder
/// panel, Settings); stretching `NSGlassEffectView`'s self-drawn Liquid Glass
/// specular/edge highlight across the entire screen is what produced a real,
/// confirmed "mysterious frame around the whole app" — this view is the
/// direct fix, replacing that edge-to-edge glass usage with a composition
/// that mirrors what the reference actually does full-screen.
final class LauncherBackgroundView: NSView {
    struct GlassMaterialParameters: Equatable {
        let wallpaperOpacity: Float
        let blurRadius: CGFloat
        let sheenOpacity: Float
    }

    struct Configuration {
        /// Off for any future narrow decorative surface — the
        /// bloom/highlight ellipses are sized for a full screen and would
        /// barely register in a small strip.
        var includeBloomHighlights: Bool = true
        /// `.glass` (the default) keeps a readable Liquid Glass-style
        /// composition: a visibly present, blurred wallpaper, a moderate
        /// scrim, and material sheen. `.wallpaper` keeps the desktop image
        /// first in the stack, optionally blurred, with only a very light
        /// translucent scrim above it so the wallpaper remains visible.
        var mode: LauncherBackgroundMode = .glass
        /// 0...1, `.glass` mode only — scales the sheen highlight's
        /// opacity. The reference's own default (0.35) is this view's
        /// existing hardcoded `sheenLayer.opacity`, so `materialIntensity
        /// == 0.35` reproduces the pre-Round-20 look exactly.
        var materialIntensity: Double = 0.35
        /// `.wallpaper` mode only — whether the wallpaper layer itself is
        /// blurred (softly, less than `.glass` mode's heavier blur) or
        /// shown crisp.
        var blursWallpaper: Bool = true
    }

    private let baseLayer = CALayer()
    private let wallpaperLayer = CALayer()
    private let scrimLayer = CAGradientLayer()
    private let sheenLayer = CAGradientLayer()
    private var bloomLayer: CALayer?
    private var highlightLayer: CALayer?
    private var fullScreenSize: CGSize
    /// This view's offset within the screen's full-frame coordinate space.
    /// The launcher owns the full target display, so the normal value is
    /// `.zero`; the parameter remains available for any bounded host view.
    private var viewportOrigin: CGPoint
    private var screen: NSScreen
    private var configuration: Configuration
    private var wallpaperRequestGeneration = 0
    private var configurationGeneration: UInt = 0
    private var configurationTask: Task<Void, Never>?
    private var wallpaperTask: Task<Void, Never>?
    /// The image request is intentionally independent from the material
    /// slider.  Re-resolving WindowServer and re-blurring the desktop for
    /// every 0.05 slider step can monopolize the main actor while the user
    /// is still dragging.  The last requested mode/blur pair is enough to
    /// decide when the wallpaper pixels themselves need to change.
    private var lastWallpaperMode: LauncherBackgroundMode?
    private var lastWallpaperBlur: Bool?

    init(screen: NSScreen, viewportOrigin: CGPoint = .zero, configuration: Configuration = .init()) {
        self.fullScreenSize = screen.frame.size
        self.viewportOrigin = viewportOrigin
        self.screen = screen
        self.configuration = configuration
        super.init(frame: .zero)
        wantsLayer = true
        guard let root = layer else { return }

        baseLayer.backgroundColor = NSColor(srgb: 0x0A0A0B).cgColor
        root.addSublayer(baseLayer)

        wallpaperLayer.contentsGravity = .resizeAspectFill
        wallpaperLayer.transform = CATransform3DMakeScale(1.14, 1.14, 1)
        root.addSublayer(wallpaperLayer)

        scrimLayer.colors = [
            // Keep the glass mode legible without crushing the wallpaper into
            // a nearly uniform blue-black surface. Together with the
            // intensity-dependent wallpaper layer this leaves roughly
            // 20–25% of the desktop's colour/contrast visible behind the UI.
            NSColor(srgb: 0x0C0C0D, alpha: 0.62).cgColor,
            NSColor(srgb: 0x101011, alpha: 0.68).cgColor
        ]
        scrimLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        scrimLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        root.addSublayer(scrimLayer)

        sheenLayer.type = .radial
        sheenLayer.colors = [
            NSColor.white.withAlphaComponent(0.10).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor,
            NSColor.clear.cgColor
        ]
        sheenLayer.locations = [0.0, 0.6, 1.0]
        // Radial gradients in Core Animation are centered/sized by
        // start/end *point* (center) and *radius* is implied by the
        // distance between them along the layer's unit square — top-center
        // start, wide end approximates the reference's
        // `radial-gradient(120% 100% at 50% 0%, ...)`.
        sheenLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        sheenLayer.endPoint = CGPoint(x: 1.1, y: -0.2)
        root.addSublayer(sheenLayer)

        if configuration.includeBloomHighlights {
            let bloom = CALayer()
            bloom.backgroundColor = NSColor.clear.cgColor
            let bloomGradient = CAGradientLayer()
            bloomGradient.type = .radial
            bloomGradient.colors = [
                NSColor(srgb: 0x78AAFF, alpha: 0.20).cgColor,
                NSColor(srgb: 0x78AAFF, alpha: 0.06).cgColor,
                NSColor.clear.cgColor
            ]
            bloomGradient.locations = [0.0, 0.45, 0.72]
            bloomGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            bloomGradient.endPoint = CGPoint(x: 1.0, y: 1.0)
            bloom.addSublayer(bloomGradient)
            self.bloomLayerGradient = bloomGradient
            root.addSublayer(bloom)
            bloomLayer = bloom
            addBloomDrift(to: bloom)

            let highlight = CALayer()
            let highlightGradient = CAGradientLayer()
            highlightGradient.type = .radial
            highlightGradient.colors = [
                NSColor.white.withAlphaComponent(0.06).cgColor,
                NSColor.clear.cgColor
            ]
            highlightGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            highlightGradient.endPoint = CGPoint(x: 1.0, y: 1.0)
            highlight.addSublayer(highlightGradient)
            self.highlightLayerGradient = highlightGradient
            root.addSublayer(highlight)
            highlightLayer = highlight
        }

        applyConfiguration()
        updateLayerFrames()
    }

    /// Applies `configuration`'s `mode`/`materialIntensity`/`blursWallpaper`
    /// to the already-built layer tree — called once from `init` and again,
    /// live, from `update(configuration:)`. Glass mode intentionally keeps
    /// the wallpaper contribution visible while retaining enough contrast for
    /// the icon grid; material intensity adjusts opacity, blur, and sheen
    /// together.
    private func applyConfiguration(
        clearWallpaper: Bool = true,
        reloadWallpaper: Bool = true
    ) {
        if reloadWallpaper {
            wallpaperTask?.cancel()
            wallpaperTask = nil
            wallpaperRequestGeneration &+= 1
        }
        let requestGeneration = wallpaperRequestGeneration
        // A request can target another display, URL, radius, or mode. Never
        // keep showing a previous display's image while that source is being
        // resolved; the opaque base is the only valid state until the current
        // desktop image decodes successfully.
        if clearWallpaper && reloadWallpaper {
            wallpaperLayer.contents = nil
        }
        switch configuration.mode {
        case .glass:
            let material = Self.glassMaterialParameters(for: configuration.materialIntensity)
            wallpaperLayer.opacity = material.wallpaperOpacity
            scrimLayer.opacity = 1
            sheenLayer.opacity = material.sheenOpacity
            if reloadWallpaper {
                lastWallpaperMode = .glass
                lastWallpaperBlur = true
                requestWallpaper(radius: material.blurRadius, generation: requestGeneration)
            }
        case .wallpaper:
            let radius: CGFloat = configuration.blursWallpaper ? 26 : 0
            wallpaperLayer.opacity = 1.0
            // Keep a very light translucent scrim above the wallpaper. This
            // preserves the wallpaper-first composition while preventing the
            // background from reading as an unmodulated opaque image behind
            // the content. It is deliberately much lighter than glass mode.
            scrimLayer.opacity = 0.14
            sheenLayer.opacity = 0
            if reloadWallpaper {
                lastWallpaperMode = .wallpaper
                lastWallpaperBlur = configuration.blursWallpaper
                requestWallpaper(radius: radius, generation: requestGeneration)
            }
        }
    }

    static func glassMaterialParameters(for materialIntensity: Double) -> GlassMaterialParameters {
        let intensity = materialIntensity.isFinite
            ? min(max(materialIntensity, 0), 1)
            : 0
        return GlassMaterialParameters(
            wallpaperOpacity: Float(0.78 - 0.37 * intensity),
            blurRadius: 30 + 40 * CGFloat(intensity),
            sheenOpacity: Float(intensity)
        )
    }

    private func requestWallpaper(radius: CGFloat, generation: Int) {
        let requestedScreen = screen
        let displayID = (
            requestedScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        )?.uint32Value ?? 0
        // Deliberately does not resolve the wallpaper source here just to log
        // it. Source resolution enumerates every window on the system via
        // `CGWindowListCopyWindowInfo` on the main thread, and the request
        // below immediately resolves it again internally — so this log line
        // was doubling the cost of every wallpaper request. The resolved
        // source is still logged, with more detail (kind, window id, cache
        // hit), by the cache's own "wallpaper descriptor" line.
        DiagnosticsLog.launcher.info(
            "wallpaper request: mode=\(self.configuration.mode.rawValue, privacy: .public), displayID=\(displayID, privacy: .public), radius=\(radius, privacy: .public)"
        )
        wallpaperTask = Task { @MainActor [weak self] in
            let image = await WallpaperImageCache.blurredWallpaperAsync(
                for: requestedScreen,
                radius: radius
            )
            guard let self,
                  !Task.isCancelled,
                  self.wallpaperRequestGeneration == generation else { return }
            guard let image else {
                // Do not substitute a synthetic asset when the OS wallpaper
                // cannot be read. The opaque base remains visible and the
                // cache diagnostics identify the display/URL failure.
                self.wallpaperLayer.contents = nil
                self.wallpaperTask = nil
                return
            }
            self.wallpaperLayer.contents = image
            self.wallpaperTask = nil
        }
    }

    /// Live-updates the background to match new Settings values — used by
    /// `LauncherWindowController.updateBackgroundSettings(mode:materialIntensity:blursWallpaper:)`
    /// so moving the material slider or flipping the mode picker takes
    /// effect immediately, matching every other Settings control's
    /// live-apply behavior.
    func update(configuration: Configuration) {
        self.configuration = configuration
        configurationGeneration &+= 1
        let generation = configurationGeneration
        let wallpaperNeedsReload = lastWallpaperMode != configuration.mode
            || lastWallpaperBlur != configuration.blursWallpaper
        configurationTask?.cancel()
        configurationTask = Task { @MainActor [weak self] in
            // Slider updates arrive in bursts. Apply one latest configuration
            // per event turn so stale blur requests never pile up.
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.configurationGeneration == generation else { return }
            // Material-only changes update the layer properties in place and
            // retain the last successfully loaded wallpaper.  A mode/blur
            // change is the only case that needs a new WindowServer/image
            // request.
            self.applyConfiguration(
                clearWallpaper: wallpaperNeedsReload,
                reloadWallpaper: wallpaperNeedsReload
            )
            self.configurationTask = nil
        }
    }

    /// Updates the display geometry when the launcher moves to another
    /// screen. The view is retained across shows, so keeping the original
    /// screen/frame would otherwise reuse the wrong wallpaper and gradient
    /// canvas on a multi-display setup.
    func update(screen: NSScreen, viewportOrigin: CGPoint? = nil) {
        // Only a genuine display change invalidates the image already on
        // screen. `LauncherWindowController.show()` calls this on *every* open,
        // and clearing unconditionally meant the wallpaper layer was reset to
        // nil right before the window became visible — so each open started on
        // the flat base color and only painted the wallpaper a run loop later,
        // once the (usually already cached) image came back through the async
        // path. Reloading still happens either way, so a wallpaper the user
        // changed since the last open is still picked up; what changes is that
        // the previous image stays on screen until the new one is ready.
        let displayChanged = Self.displayID(of: self.screen) != Self.displayID(of: screen)
        self.screen = screen
        fullScreenSize = screen.frame.size
        if let viewportOrigin {
            self.viewportOrigin = viewportOrigin
        }
        configurationTask?.cancel()
        configurationTask = nil
        configurationGeneration &+= 1
        applyConfiguration(clearWallpaper: displayChanged)
        updateLayerFrames()
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    // Radial CAGradientLayers need their own bounds set explicitly (they
    // don't auto-track a differently-shaped parent), so the bloom/highlight
    // gradients are kept as direct properties for `updateLayerFrames` to
    // resize alongside their containing layer.
    private var bloomLayerGradient: CAGradientLayer?
    private var highlightLayerGradient: CAGradientLayer?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateLayerFrames()
    }

    /// Every layer below is framed at the *whole screen's* size (not this
    /// view's own, possibly smaller visible-frame bounds) and shifted by
    /// `-viewportOrigin` so gradients and wallpaper remain aligned with the
    /// display's full-frame coordinate space.
    private func updateLayerFrames() {
        let size = fullScreenSize
        let origin = CGPoint(x: -viewportOrigin.x, y: -viewportOrigin.y)
        let bounds = CGRect(origin: origin, size: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        baseLayer.frame = bounds
        wallpaperLayer.frame = bounds
        scrimLayer.frame = bounds
        sheenLayer.frame = bounds

        // Sized as a fraction of the real screen rather than the
        // reference's own fixed 1440x900-canvas pixel values, so this
        // looks proportionally correct on any real display.
        if let bloomLayer, let bloomLayerGradient {
            let bloomSize = CGSize(width: size.width * (620.0 / 1440.0), height: size.height * (520.0 / 900.0))
            bloomLayer.frame = CGRect(
                x: origin.x + size.width - bloomSize.width * 0.72,
                y: origin.y - bloomSize.height * 0.35,
                width: bloomSize.width,
                height: bloomSize.height
            )
            bloomLayerGradient.frame = bloomLayer.bounds
        }
        if let highlightLayer, let highlightLayerGradient {
            let highlightSize = CGSize(width: size.width * (420.0 / 1440.0), height: size.height * (360.0 / 900.0))
            highlightLayer.frame = CGRect(
                x: origin.x - highlightSize.width * 0.35,
                y: origin.y + size.height - highlightSize.height * 0.65,
                width: highlightSize.width,
                height: highlightSize.height
            )
            highlightLayerGradient.frame = highlightLayer.bounds
        }

        CATransaction.commit()
    }

    /// Matches the reference's own `bloomDrift` CSS keyframe animation
    /// (the reference mockup's `@keyframes bloomDrift`, 26s ease-in-out loop) —
    /// a slow, subtle wander so the background doesn't read as a static
    /// image.
    private func addBloomDrift(to layer: CALayer) {
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = [
            CATransform3DIdentity,
            CATransform3DConcat(CATransform3DMakeTranslation(-28, -18, 0), CATransform3DMakeScale(1.08, 1.08, 1)),
            CATransform3DIdentity
        ]
        animation.keyTimes = [0, 0.5, 1.0]
        animation.duration = 26
        animation.repeatCount = .infinity
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        layer.add(animation, forKey: "bloomDrift")
    }
}

private extension NSColor {
    convenience init(srgb hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
