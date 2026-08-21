import AppKit
import CoreGraphics
import Diagnostics

/// The launcher's full-frame borderless overlay. It stays on the current
/// desktop instead of entering AppKit's dedicated full-screen Space.
final class LauncherWindow: NSWindow {
    var onCancel: (() -> Void)?
    var onCloseWindow: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onFocusSearch: (() -> Void)?

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
        // Deliberately `false`, despite the goal of never leaving the overlay
        // above the app the user just opened. `show()` flips the process
        // between `.accessory` and `.regular` on every open; AppKit re-evaluates
        // activation across that switch, and `hidesOnDeactivate` reacts to a
        // momentary resign by ordering the window out with no way to opt out —
        // producing exactly the "opens, then vanishes immediately" symptom this
        // file's own `show()` comment already records from a prior ordering bug.
        // It also orders out behind the controller's back, stranding the
        // activation policy at `.regular`. `LauncherWindowController`'s
        // `appActivationObserver` covers the real case (another app activating)
        // with an `isThisApp` guard that AppKit's blanket behavior lacks.
        hidesOnDeactivate = false
        // Preserve mouse-move delivery for AppKit's normal window handling;
        // the controller intentionally does not install a global mouse-move
        // monitor, which would create a task for every pointer event.
        acceptsMouseMovedEvents = true
    }

    /// Keep the overlay just below the Dock unless the user explicitly asks to
    /// hide it: the real Dock stays above the launcher in the default
    /// presentation, while the overlay still sits above every ordinary
    /// application window. `.normal` is deliberately *not* used here — it is
    /// the same level every other app's windows occupy, so a full-display
    /// overlay at that level has no guaranteed ordering against them and gets
    /// covered as soon as anything else takes activation.
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "w":
            onCloseWindow?()
            return true
        case ",":
            onOpenSettings?()
            return true
        case "f":
            onFocusSearch?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
