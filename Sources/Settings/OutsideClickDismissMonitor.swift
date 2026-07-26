import AppKit
import Diagnostics

/// Dismisses a floating panel (Settings, the Uninstall panel) when the user
/// clicks anywhere outside its own window — without ever affecting the
/// launcher window that keeps rendering underneath.
///
/// `LauncherWindowController`'s own `outsideClickMonitor` uses
/// `NSEvent.addGlobalMonitorForEvents`, which — per AppKit's documented
/// behavior — only fires for events destined for *other applications'*
/// windows. Since this panel floats *over* the full-screen launcher,
/// essentially every "click outside the panel" lands on the launcher's own
/// window (same app), which that global monitor structurally cannot see.
/// `NSEvent.addLocalMonitorForEvents(matching:)` sees every mouseDown routed
/// to this application, for any of its own windows, *before* AppKit's normal
/// dispatch delivers it to a responder — returning `nil` from the handler
/// suppresses that delivery entirely. That is what lets this consume the
/// dismiss-triggering click before it ever reaches
/// `BackgroundClickCatcherView.mouseDown` (whose handler hides the
/// *launcher*) — letting the click through unconsumed would fire that
/// hide() on the very click meant only to dismiss this panel, which is
/// exactly the regression this type exists to prevent.
/// No `deinit` cleanup here deliberately — Swift's `deinit` is always
/// `nonisolated`, even on a `@MainActor` class, and can't touch this
/// actor-isolated `monitor` state. Every owner of this type must call
/// `stop()` explicitly at its own teardown point (both current owners,
/// `SettingsWindowController`/`UninstallPanelWindowController`, do so in
/// their `windowWillClose`).
@MainActor
final class OutsideClickDismissMonitor {
    private var monitor: Any?
    private weak var panelWindow: NSWindow?
    private let onDismiss: () -> Void

    init(panelWindow: NSWindow, onDismiss: @escaping () -> Void) {
        self.panelWindow = panelWindow
        self.onDismiss = onDismiss
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panelWindow = self.panelWindow, panelWindow.isVisible else { return event }
            guard let eventWindow = event.window, !self.isInside(eventWindow, of: panelWindow) else { return event }
            DiagnosticsLog.settings.info("OutsideClickDismissMonitor: consuming click outside panel")
            self.onDismiss()
            return nil // consume — must never reach the launcher's BackgroundClickCatcherView
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Treats the panel's own sheets (e.g. an `NSAlert`/`NSOpenPanel`
    /// presented from it) as "inside," so interacting with them never
    /// mistakenly dismisses the panel underneath mid-interaction.
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
