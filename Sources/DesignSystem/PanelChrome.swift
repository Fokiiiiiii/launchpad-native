import AppKit
import SwiftUI

/// Shared chrome for the app's borderless glass panels — Settings, the
/// uninstall panel, the onboarding wizard and What's New.
///
/// These panels hide every piece of native window chrome, traffic lights
/// included, so each one has to bring its own way to be closed and its own
/// placement. Each module used to carry a copy of that code, and the copies
/// had drifted: one panel could not be closed with Command-W, another drew a
/// grey `xmark.circle` where the rest draw the red traffic-light dot.

/// A panel window with no native chrome that still closes the way a window
/// should: Escape and Command-W. Mirrors `LauncherWindow`'s own
/// `cancelOperation` override rather than inventing a second Escape
/// mechanism next to the click-based `OutsideClickDismissMonitor`.
public final class DismissableWindow: NSWindow {
    public var onCancel: (() -> Void)?

    // A borderless window is not granted key status by default, and these
    // panels host real controls and text fields.
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "w" else {
            return super.performKeyEquivalent(with: event)
        }
        onCancel?()
        return true
    }
}

/// Dismisses a floating panel when the user clicks anywhere outside it,
/// without disturbing the launcher rendering underneath.
///
/// `LauncherWindowController`'s own monitor uses
/// `NSEvent.addGlobalMonitorForEvents`, which by AppKit's documented behavior
/// only fires for events bound for *other applications*. A panel floating over
/// the full-screen launcher means essentially every outside click lands on the
/// launcher's own window — same app — which that monitor structurally cannot
/// see. The local monitor sees every mouseDown routed to this application
/// before normal dispatch, and returning `nil` suppresses delivery. That is
/// what keeps the dismissing click from also reaching
/// `BackgroundClickCatcherView.mouseDown`, which would hide the launcher too.
///
/// There is deliberately no `deinit` cleanup: `deinit` is always
/// `nonisolated`, even on a `@MainActor` class, so it cannot touch this
/// isolated state. Owners call `stop()` at their own teardown point.
@MainActor
public final class OutsideClickDismissMonitor {
    private var monitor: Any?
    private weak var panelWindow: NSWindow?
    private let onDismiss: () -> Void

    public init(panelWindow: NSWindow, onDismiss: @escaping () -> Void) {
        self.panelWindow = panelWindow
        self.onDismiss = onDismiss
    }

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panelWindow = self.panelWindow, panelWindow.isVisible else { return event }
            guard let eventWindow = event.window, !self.isInside(eventWindow, of: panelWindow) else { return event }
            self.onDismiss()
            return nil // consume — must never reach the launcher's background click catcher
        }
    }

    public func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// A panel's own sheets — an `NSAlert` or `NSOpenPanel` it presented —
    /// count as inside, so interacting with one never dismisses the panel
    /// underneath mid-interaction.
    private func isInside(_ window: NSWindow, of panelWindow: NSWindow) -> Bool {
        if window === panelWindow { return true }
        if window.sheetParent === panelWindow { return true }
        var parent = window.parent
        while let candidate = parent {
            if candidate === panelWindow { return true }
            parent = candidate.parent
        }
        return false
    }
}

/// Places a panel in the middle of the screen the launcher is on, falling
/// back to AppKit's own centering when there is no screen to aim at.
@MainActor
public enum PanelPlacement {
    public static func center(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else {
            window.center()
            return
        }
        let target = screen.visibleFrame
        window.setFrameOrigin(
            NSPoint(
                x: target.midX - window.frame.width / 2,
                y: target.midY - window.frame.height / 2
            )
        )
    }
}

/// The in-content close affordance. Outside-click and Escape are not
/// discoverable on their own, so every panel draws this in the familiar
/// traffic-light position; the glyph appears on hover, as the native control
/// does.
public struct PanelCloseButton: View {
    private let accessibilityLabel: String
    private let action: () -> Void

    @State private var isHovering = false

    public init(accessibilityLabel: String, action: @escaping () -> Void) {
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                    .overlay {
                        Circle()
                            .strokeBorder(.black.opacity(0.18), lineWidth: 0.5)
                    }
                Image(systemName: "xmark")
                    .font(.system(size: 6.5, weight: .black))
                    .foregroundStyle(.black.opacity(0.62))
                    .opacity(isHovering ? 1 : 0)
            }
            .frame(width: 13, height: 13)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Bookkeeping every glass panel repeats: the outside-click monitor's
/// lifetime, and whether closing should hand key status back to the launcher.
///
/// Handing key status back is not unconditional. The launcher's `hide()`
/// orders its window out only after a fade, so `isVisible` stays true
/// throughout — and a panel closed *because* the launcher is going away would
/// otherwise reclaim focus from whatever the user just switched to. Closing
/// along that path suppresses the reclaim.
///
/// The callback fires one run loop later rather than synchronously: called
/// inside `windowWillClose`, `NSWindow.close()`'s own remaining work runs
/// afterwards and takes key status back again.
@MainActor
public final class PanelDismissal {
    private let onWillClose: () -> Void
    private var monitor: OutsideClickDismissMonitor?
    private var suppressesNextKeyReclaim = false

    public init(onWillClose: @escaping () -> Void) {
        self.onWillClose = onWillClose
    }

    public var isMonitoring: Bool { monitor != nil }

    public func startMonitoring(panelWindow: NSWindow, onOutsideClick: @escaping () -> Void) {
        guard monitor == nil else { return }
        let monitor = OutsideClickDismissMonitor(panelWindow: panelWindow, onDismiss: onOutsideClick)
        monitor.start()
        self.monitor = monitor
    }

    public func stopMonitoring() {
        monitor?.stop()
        monitor = nil
    }

    public func suppressNextKeyReclaim() {
        suppressesNextKeyReclaim = true
    }

    /// Call from `windowWillClose(_:)`.
    public func windowWillClose() {
        stopMonitoring()
        let shouldReclaim = !suppressesNextKeyReclaim
        suppressesNextKeyReclaim = false
        guard shouldReclaim else { return }
        DispatchQueue.main.async { [onWillClose] in
            onWillClose()
        }
    }
}
