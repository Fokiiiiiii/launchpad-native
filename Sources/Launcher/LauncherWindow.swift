import AppKit
import CoreGraphics

/// Borderless overlay panel, not a normal document window: it can become key
/// (so the search field can type) but never main, joins every Space, and
/// floats above fullscreen apps via `collectionBehavior`.
final class LauncherWindow: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    convenience init(contentRect: NSRect, hideDock: Bool = false) {
        self.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        applyDockVisibilityPreference(hideDock: hideDock)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isMovable = false
        hidesOnDeactivate = false
    }

    /// `.popUpMenu` (101) sat well above the real Dock's window level
    /// (`CGWindowLevelForKey(.dockWindow)`, ~20), so the launcher always
    /// painted over the Dock, hiding it — unlike real Launchpad, where the
    /// Dock stays visible on top. `CGWindowLevelForKey`/`.dockWindow` are
    /// public CoreGraphics API (Quartz Window Services), not private.
    ///
    /// `hideDock` (the Settings "Hide Dock" toggle, default off) switches
    /// which side of the Dock's own level the launcher sits on: off (the
    /// default) keeps the launcher one level *below* the Dock so it renders
    /// on top, matching real Launchpad; on puts the launcher one level
    /// *above* instead, so it paints over the Dock — the pre-Phase-14
    /// behavior, now opt-in. Either way this never touches the real Dock
    /// process or macOS's own autohide setting — only this window's own
    /// level changes.
    func applyDockVisibilityPreference(hideDock: Bool) {
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        level = NSWindow.Level(rawValue: hideDock ? dockLevel + 1 : dockLevel - 1)
    }

    /// Escape reaches here via the standard responder chain when no control
    /// consumes it first (search field included), which is how AppKit
    /// surfaces "the user pressed Escape" without a raw keyDown override.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
