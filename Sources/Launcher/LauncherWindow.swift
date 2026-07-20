import AppKit

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
        level = .popUpMenu
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
