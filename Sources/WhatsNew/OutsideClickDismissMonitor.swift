import AppKit
import Diagnostics

/// `WhatsNew`-module-local duplicate of `Settings.OutsideClickDismissMonitor`
/// — dismisses this floating panel when the user clicks anywhere outside its
/// own window, without ever affecting the launcher window rendering
/// underneath. See that type's own doc comment for the full reasoning
/// (`NSEvent.addLocalMonitorForEvents` vs. `addGlobalMonitorForEvents`), and
/// `WhatsNewGlassBackground.swift`'s doc comment for why this module keeps
/// its own small copies instead of depending on `Settings`.
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
            DiagnosticsLog.whatsNew.info("OutsideClickDismissMonitor: consuming click outside panel")
            self.onDismiss()
            return nil // consume — must never reach the launcher's BackgroundClickCatcherView
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

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
