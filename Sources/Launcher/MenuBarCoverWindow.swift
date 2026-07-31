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
        let menuBarHeight = NSStatusBar.system.thickness
        let rect = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - menuBarHeight,
            width: screen.frame.width,
            height: menuBarHeight
        )
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = true
        // A dark, neutral tone close to the rest of the launcher's own
        // glass-over-blurred-desktop look, so the covered strip doesn't read
        // as an obviously different flat rectangle.
        backgroundColor = NSColor(white: 0.07, alpha: 1.0)
        hasShadow = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    }

    /// Repositions to a (possibly different) screen's menu bar rect —
    /// called every time the launcher itself shows, mirroring how
    /// `LauncherWindowController.show()` already recomputes its own frame
    /// against `Self.targetScreen()` on every call rather than assuming the
    /// screen never changes between shows.
    func reposition(on screen: NSScreen) {
        let menuBarHeight = NSStatusBar.system.thickness
        setFrame(
            NSRect(
                x: screen.frame.minX,
                y: screen.frame.maxY - menuBarHeight,
                width: screen.frame.width,
                height: menuBarHeight
            ),
            display: true
        )
    }
}
