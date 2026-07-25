import AppKit
import CoreGraphics

/// Borderless overlay panel, not a normal document window: it can become key
/// (so the search field can type) but never main, joins every Space, and
/// floats above fullscreen apps via `collectionBehavior`.
final class LauncherWindow: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    convenience init(contentRect: NSRect) {
        self.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // `.popUpMenu` (101) sat well above the real Dock's window level
        // (`CGWindowLevelForKey(.dockWindow)`, ~20), so the launcher always
        // painted over the Dock, hiding it — unlike real Launchpad, where
        // the Dock stays visible on top. `CGWindowLevelForKey` and
        // `.dockWindow` are public CoreGraphics API (Quartz Window
        // Services), not a private one — placing this window one level
        // below the Dock's own keeps the same "floats above regular/
        // fullscreen app windows" behavior while letting the real Dock
        // render in front, matching the user's explicit ask.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isMovable = false
        hidesOnDeactivate = false
    }

    /// Escape reaches here via the standard responder chain when no control
    /// consumes it first (search field included), which is how AppKit
    /// surfaces "the user pressed Escape" without a raw keyDown override.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
