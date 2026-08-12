import AppKit
import CoreGraphics
import Diagnostics

/// The launcher's full-frame borderless overlay. It stays on the current
/// desktop instead of entering AppKit's dedicated full-screen Space.
final class LauncherWindow: NSWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    convenience init(contentRect: NSRect, hideDock: Bool = false) {
        self.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        applyDockVisibilityPreference(hideDock: hideDock, reason: "init")
        // `toggleFullScreen` creates a separate Space. The launcher is an
        // overlay, so join the current/all Spaces and remain auxiliary to an
        // existing fullscreen app instead of becoming a new fullscreen app.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isMovable = false
        hidesOnDeactivate = false
        // Preserve mouse-move delivery for AppKit's normal window handling;
        // the controller intentionally does not install a global mouse-move
        // monitor, which would create a task for every pointer event.
        acceptsMouseMovedEvents = true
    }

    /// Keep the overlay below the Dock unless the user explicitly asks to
    /// hide it. The real Dock must remain above the launcher in the default
    /// presentation.
    func applyDockVisibilityPreference(
        hideDock: Bool,
        reason: String = "unspecified",
        screenFrame: NSRect? = nil
    ) {
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        level = NSWindow.Level(rawValue: hideDock ? dockLevel + 1 : dockLevel - 1)
        if let displayFrame = screenFrame ?? screen?.frame {
            setFrame(displayFrame, display: true)
        }
        DiagnosticsLog.launcher.info(
            "dock visibility policy: hideDock=\(hideDock, privacy: .public), level=\(self.level.rawValue, privacy: .public), dockLevel=\(dockLevel, privacy: .public), reason=\(reason, privacy: .public)"
        )
    }

    /// Escape reaches here via the standard responder chain when no control
    /// consumes it first (search field included), which is how AppKit
    /// surfaces "the user pressed Escape" without a raw keyDown override.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
