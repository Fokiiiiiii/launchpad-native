import AppKit
import Persistence
import QuartzCore

/// Full-screen decorative background matching the "Tessera" design
/// reference's own `TSBackground` composition (`TesseraDesign.swift`'s
/// `.glass` mode / `Tessera.dc.html`'s Stage layer stack): a base fill, a
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
final class TesseraBackgroundView: NSView {
    struct Configuration {
        /// Off for `MenuBarCoverWindow`'s narrow strip — the bloom/highlight
        /// ellipses are sized for a full screen and would barely register
        /// (or render as an odd partial smear) in a <40pt-tall bar, and
        /// keeping two independently-animated windows' blooms phase-locked
        /// isn't worth the complexity for something that wouldn't be visible
        /// anyway.
        var includeBloomHighlights: Bool = true
        /// `.glass` (the default) is byte-for-byte the composition this
        /// view already drew before Round 20 — a dimmed/tinted wallpaper
        /// with a dark scrim and material sheen. `.wallpaper` shows the
        /// desktop wallpaper close to full opacity with no scrim, matching
        /// the reference's own `TSBackgroundMode.wallpaper`.
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
    private let fullScreenSize: CGSize
    /// This view's own position within the full screen, in the screen's own
    /// bottom-left-origin coordinate space (`NSScreen.frame`'s own
    /// convention). Real, confirmed report ("メニューバーの上の部分が黒く
    /// なっている"): `MenuBarCoverWindow` and `LauncherWindowController`
    /// each construct their own independent `TesseraBackgroundView`
    /// instance, and every gradient here (`scrimLayer`/`sheenLayer`) is
    /// positioned in *that layer's own* unit square — each view previously
    /// treated its own bounds as if it were the entire screen, so the menu
    /// bar strip's gradients ran their own independent 0-to-1 sweep across
    /// its ~31pt height while the main window ran the *same* 0-to-1 sweep
    /// across its ~1000pt+ height. Two independently-normalized gradients
    /// meeting at a shared edge don't produce continuous values there —
    /// this is why the strip visibly reads as a flat, separate band instead
    /// of blending into what's directly below it. Fed with the *whole
    /// screen's* size and this view's own offset within it, every layer
    /// below is now framed at full-screen size and shifted by
    /// `-viewportOrigin` — each view becomes a window looking into one
    /// shared, continuous composition instead of computing its own
    /// self-contained one.
    private let viewportOrigin: CGPoint
    private let screen: NSScreen
    private var configuration: Configuration

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
            NSColor(srgb: 0x0C0C0D, alpha: 0.92).cgColor,
            NSColor(srgb: 0x101011, alpha: 0.94).cgColor
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
    /// live, from `update(configuration:)`. `.glass` reproduces this view's
    /// original, pre-Round-20 fixed values exactly (`wallpaperLayer.opacity
    /// == 0.30`, full scrim, `sheenLayer.opacity == 0.35` when
    /// `materialIntensity == 0.35`) — a user who never touches the new
    /// Settings controls sees no visual change at all.
    private func applyConfiguration() {
        switch configuration.mode {
        case .glass:
            wallpaperLayer.contents = TesseraWallpaperImageCache.blurredWallpaper(for: screen)
            wallpaperLayer.opacity = 0.30
            scrimLayer.opacity = 1
            sheenLayer.opacity = Float(configuration.materialIntensity)
        case .wallpaper:
            let radius: CGFloat = configuration.blursWallpaper ? 26 : 0
            wallpaperLayer.contents = TesseraWallpaperImageCache.blurredWallpaper(for: screen, radius: radius)
            wallpaperLayer.opacity = 1.0
            scrimLayer.opacity = 0
            sheenLayer.opacity = 0
        }
    }

    /// Live-updates the background to match new Settings values — used by
    /// `LauncherWindowController.updateBackgroundSettings(mode:materialIntensity:blursWallpaper:)`
    /// so moving the material slider or flipping the mode picker takes
    /// effect immediately, matching every other Settings control's
    /// live-apply behavior.
    func update(configuration: Configuration) {
        self.configuration = configuration
        applyConfiguration()
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
    /// view's own, possibly much smaller, bounds) and shifted by
    /// `-viewportOrigin` — see `viewportOrigin`'s doc comment for why. A
    /// view whose `viewportOrigin` is `.zero` and whose own bounds already
    /// equal `fullScreenSize` (the main launcher window) behaves exactly as
    /// before this change; only a narrower/offset view (the menu bar cover)
    /// changes behavior.
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
    /// (`Tessera.dc.html`'s `@keyframes bloomDrift`, 26s ease-in-out loop) —
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
