import AppKit
import Diagnostics
#if LAUNCHPAD_DEBUG_HOOKS
import ImageIO
#endif
import Persistence
import QuartzCore
#if LAUNCHPAD_DEBUG_HOOKS
import UniformTypeIdentifiers
#endif


import SwiftUI

@MainActor
enum LauncherMaterialSurface {
    static func presetIndex(for intensity: Double) -> Int {
        guard intensity.isFinite else { return 1 }
        return min(max(Int((min(max(intensity, 0), 1) * 4).rounded()), 0), 4)
    }

    static func material(for intensity: Double) -> NSVisualEffectView.Material {
        switch presetIndex(for: intensity) {
        case 0: .hudWindow
        case 1: .fullScreenUI
        case 2: .popover
        case 3: .menu
        default: .underWindowBackground
        }
    }

    static func makeView() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

}

final class LauncherBackgroundView: NSView {


    struct Configuration {
        var mode: LauncherBackgroundMode = .glass
        var materialIntensity: Double = 0.35
        var blursWallpaper: Bool = true
        var wallpaperBlurRadius: Double = 8
    }

    private let baseLayer = CALayer()
    private let wallpaperLayer = CALayer()
    private let scrimLayer = CAGradientLayer()
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
    /// The blur radius the wallpaper on screen was prepared with.
    private var lastWallpaperRadius: CGFloat?
    /// `init` requests the wallpaper for the screen it is handed, and
    /// `LauncherWindowController.show()` then calls `update(screen:)` on the
    /// view it just built. Resolving the source is not free — it enumerates
    /// every window on the system, on the main thread — so the first update
    /// after construction skips the reload when the screen has not changed.
    private var isFirstScreenUpdateAfterInit = true

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
        wallpaperLayer.masksToBounds = true
        wallpaperLayer.actions = ["contents": NSNull(), "filters": NSNull(), "opacity": NSNull(),
                                  "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        root.addSublayer(wallpaperLayer)

        scrimLayer.colors = [NSColor.black.cgColor, NSColor.black.cgColor]
        root.addSublayer(scrimLayer)

        materialHost.frame = bounds
        materialHost.autoresizingMask = [.width, .height]
        addSubview(materialHost)
        applyConfiguration()
        updateLayerFrames()
    }

    /// Applies `configuration`'s `mode`/`materialIntensity`/`blursWallpaper`
    /// to the already-built layer tree — called once from `init` and again,
    /// live, from `update(configuration:)`. Glass mode intentionally keeps
    /// the wallpaper contribution visible while retaining enough contrast for
    /// the icon grid; material intensity adjusts opacity, blur, and sheen
    /// together.

    private lazy var materialHost = LauncherMaterialSurface.makeView()

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
        let showsGlass = configuration.mode == .glass
        materialHost.isHidden = !showsGlass
        materialHost.material = LauncherMaterialSurface.material(for: configuration.materialIntensity)
        baseLayer.isHidden = showsGlass
        wallpaperLayer.isHidden = showsGlass
        scrimLayer.isHidden = showsGlass
        scrimLayer.opacity = Self.wallpaperDimOpacity(isBlurred: configuration.blursWallpaper)
        switch configuration.mode {
        case .glass:
            if reloadWallpaper {
                lastWallpaperMode = .glass
                lastWallpaperRadius = 0
            }
        case .wallpaper:
            let radius = Self.wallpaperBlurRadius(isEnabled: configuration.blursWallpaper, radius: configuration.wallpaperBlurRadius)
            wallpaperLayer.opacity = 1
            if reloadWallpaper {
                lastWallpaperMode = .wallpaper
                lastWallpaperRadius = radius
                requestWallpaper(radius: radius, generation: requestGeneration)
            }
        }
    }



    static func wallpaperBlurRadius(isEnabled: Bool, radius: Double = 8) -> CGFloat {
        isEnabled && radius.isFinite ? CGFloat(min(max(radius, 0), 40)) : 0
    }

    static func wallpaperDimOpacity(isBlurred: Bool) -> Float {
        isBlurred ? 0.3 : 0.2
    }

    /// Radii closer than this look the same, so a slider drag does not decode and
    /// blur the wallpaper again for every step of it.
    private static let radiusReloadStep: CGFloat = 4

    /// The blur radius a configuration asks for: the glass strength's in glass
    /// mode (the "blur wallpaper" switch is not consulted there), the switch's
    /// otherwise.
    static func requestedBlurRadius(for configuration: Configuration) -> CGFloat {
        switch configuration.mode {
        case .glass: return 0
        case .wallpaper: return wallpaperBlurRadius(isEnabled: configuration.blursWallpaper, radius: configuration.wallpaperBlurRadius)
        }
    }

    /// Whether the image on screen was prepared differently from what the
    /// configuration now asks for. It used to compare the mode and the switch
    /// only: glass strength never reached the blur until something else forced a
    /// reload, and in glass mode a switch left off made every slider step count as
    /// a change.
    static func needsWallpaperReload(
        lastMode: LauncherBackgroundMode?,
        lastRadius: CGFloat?,
        configuration: Configuration
    ) -> Bool {
        guard lastMode == configuration.mode, let lastRadius else { return true }
        let step: CGFloat = configuration.mode == .wallpaper ? 0.5 : radiusReloadStep
        return abs(lastRadius - requestedBlurRadius(for: configuration)) >= step
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
            if self.wallpaperLayer.contents != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let transition = CATransition()
                transition.type = .fade
                transition.duration = 0.2
                self.wallpaperLayer.add(transition, forKey: "wallpaperTransition")
            }
            self.wallpaperLayer.contents = image
            self.wallpaperTask = nil
#if LAUNCHPAD_DEBUG_HOOKS
            Self.debugDumpWallpaper(image)
#endif
        }
    }

#if LAUNCHPAD_DEBUG_HOOKS
    /// Debug-only: `LAUNCHPAD_DEBUG_DUMP_WALLPAPER=<path.png>` writes out the
    /// image this view just put on screen. A screenshot cannot stand in for
    /// it: a dimmed or locked display captures as black, and on macOS 27
    /// reading the desktop back needs the Screen Recording permission this app
    /// deliberately does not ask for.
    private static func debugDumpWallpaper(_ image: CGImage) {
        guard let path = ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_DUMP_WALLPAPER"], !path.isEmpty,
              let destination = CGImageDestinationCreateWithURL(
                  URL(fileURLWithPath: path) as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        let written = CGImageDestinationFinalize(destination)
        DiagnosticsLog.launcher.info(
            "debugDumpWallpaper: \(image.width, privacy: .public)x\(image.height, privacy: .public), written=\(written, privacy: .public)"
        )
    }
#endif

    func update(configuration: Configuration) {
        self.configuration = configuration
        configurationGeneration &+= 1
        let generation = configurationGeneration
        let wallpaperNeedsReload = Self.needsWallpaperReload(
            lastMode: lastWallpaperMode,
            lastRadius: lastWallpaperRadius,
            configuration: configuration
        )
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
                clearWallpaper: self.lastWallpaperMode != configuration.mode,
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
        let isRedundantFirstUpdate = isFirstScreenUpdateAfterInit && !displayChanged
        isFirstScreenUpdateAfterInit = false
        applyConfiguration(clearWallpaper: displayChanged, reloadWallpaper: !isRedundantFirstUpdate)
        updateLayerFrames()
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    // Radial CAGradientLayers need their own bounds set explicitly (they
    // don't auto-track a differently-shaped parent), so the bloom/highlight
    // gradients are kept as direct properties for `updateLayerFrames` to
    // resize alongside their containing layer.

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

        CATransaction.commit()
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
