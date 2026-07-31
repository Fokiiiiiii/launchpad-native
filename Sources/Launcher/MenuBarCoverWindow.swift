import AppKit
import CoreGraphics

/// A more fundamental fix for "the real macOS menu bar shows over the
/// launcher" than the two previous attempts (re-asserting
/// `.autoHideMenuBar` on every `windowDidBecomeKey` for Settings/Uninstall;
/// hiding the launcher on `NSWorkspace.didActivateApplicationNotification`)
/// — both left the real menu bar visible per repeated user screenshots.
/// `NSApp.presentationOptions.autoHideMenuBar` depends on WindowServer's own
/// undocumented "is this app really presenting fullscreen-style content"
/// heuristic; `LauncherWindow`'s `.fullScreenAuxiliary` (never
/// `.fullScreenPrimary` — nothing in this app ever enters genuine
/// `NSWindow` fullscreen) may simply never satisfy it, regardless of how
/// faithfully the option bit itself is set and re-asserted.
///
/// Rather than keep chasing that cooperative, apparently-unreliable
/// mechanism, this window physically paints over the menu bar's own screen
/// rect with an opaque layer at a level *above* the real menu bar's own
/// window level (`CGWindowLevelForKey(.mainMenuWindow)`) — reliable by
/// construction (ordinary window z-order compositing) rather than dependent
/// on the OS's cooperation. The real menu bar is still there and
/// functional underneath (`ignoresMouseEvents = true` lets clicks pass
/// through to it — so far-right status items like Wi-Fi/battery/clock stay
/// genuinely usable), it's just no longer visible.
final class MenuBarCoverWindow: NSWindow {
    init(screen: NSScreen) {
        let rect = Self.coverRect(for: screen)
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        // Real, confirmed complaint #1: a flat solid fill ("メニューバーの
        // カバーの部分の色合いがおかしい") read as an obviously different,
        // wrong-toned rectangle sitting right above the launcher's own
        // translucent glass-over-blurred-desktop background — a flat opaque
        // color can't track whatever the desktop wallpaper actually looks
        // like the way the glass view below it does.
        //
        // Real, confirmed complaint #2 (after switching to bare
        // `GlassBackgroundFactory.makeBackground`): the real menu bar's
        // icons/text were still faintly legible through the blur — a single
        // Gaussian-blur pass softens edges but doesn't fully erase small,
        // high-contrast vector content, and `GlassBackgroundFactory`'s own
        // tint (`black.withAlphaComponent(0.08)`) was deliberately tuned
        // for *lightly* tinting a photographic wallpaper, not for reliably
        // hiding detailed content — two different jobs that don't share the
        // same strength requirement even though they share the same blur
        // technique. Confirmed by reading `GlassBackgroundView.swift`'s own
        // doc comments, which explicitly describe that 8% tint as chosen to
        // avoid "crushing the desktop wallpaper," the opposite of what this
        // cover needs.
        //
        // Fix: keep the glass material (visual continuity with the
        // launcher's own background survives), but layer a much stronger
        // opaque-ish dark overlay (60% black) on top — enough to reliably
        // erase icon/text detail while still letting ~40% of the blurred
        // brightness/color variation show through, so it still reads as
        // "this app's own dark glass," not an unrelated flat patch.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]

        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        container.autoresizingMask = [.width, .height]

        let glass = GlassBackgroundFactory.makeBackground(cornerRadius: 0)
        glass.frame = container.bounds
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)

        let scrim = NSView(frame: container.bounds)
        scrim.autoresizingMask = [.width, .height]
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        container.addSubview(scrim)

        contentView = container
    }

    /// Repositions to a (possibly different) screen's menu bar rect —
    /// called every time the launcher itself shows, mirroring how
    /// `LauncherWindowController.show()` already recomputes its own frame
    /// against `Self.targetScreen()` on every call rather than assuming the
    /// screen never changes between shows.
    func reposition(on screen: NSScreen) {
        setFrame(Self.coverRect(for: screen), display: true)
    }

    /// Real, confirmed bug (a real screenshot showed a 1-3px sliver of the
    /// real menu bar still visible above this cover): `NSStatusBar.system.thickness`
    /// is a fixed status-item sizing constant (24pt on a typical Mac), not a
    /// live measurement of the real OS-reserved menu-bar strip — which is
    /// taller than that on notched displays (the whole strip renders taller
    /// everywhere on those displays, not just around the camera housing, to
    /// stay a consistent height). Mirrors `GridViewController`'s own
    /// `dockReservedHeight` pattern (see its doc comment): `screen.frame.maxY
    /// - screen.visibleFrame.maxY` is the same "public, always-current
    /// source of truth" already proven for the Dock, applied here to the
    /// menu bar's own reserved strip instead. `screen.safeAreaInsets.top`
    /// (macOS 12+) is compared too and matters independently of the
    /// `visibleFrame` term: `LauncherWindowController.show()` calls
    /// `NSApp.presentationOptions.insert(.autoHideMenuBar)` immediately
    /// before this runs, and `visibleFrame` can reflect *this app's own*
    /// requested presentation state (reading as if no menu bar space is
    /// reserved at all) rather than the real on-screen state —
    /// `safeAreaInsets.top` is a physical-display-geometry property, not an
    /// available-drawable-area property, so it stays reliable in that case.
    /// `NSStatusBar.system.thickness` remains in the `max()` as a hard
    /// floor, so this never regresses below the original behavior even when
    /// the other two terms read as 0. The final `+1pt` pad is cheap
    /// insurance against sub-point/backing-pixel rounding at
    /// window-frame-setting time — harmless since `ignoresMouseEvents =
    /// true` makes any resulting over-coverage a no-op.
    private static func coverRect(for screen: NSScreen) -> NSRect {
        let measured = max(
            screen.frame.maxY - screen.visibleFrame.maxY,
            screen.safeAreaInsets.top,
            NSStatusBar.system.thickness
        )
        let padded = measured + 1
        return NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - padded,
            width: screen.frame.width,
            height: padded
        )
    }
}
