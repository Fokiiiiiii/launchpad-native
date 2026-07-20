import AppKit
import Grid
import SwiftUI

/// A normal (non-panel) window — unlike the launcher, Settings should behave
/// like an ordinary Mac preferences window: it can be the key/main window,
/// stays open across Spaces switches, and doesn't auto-dismiss on an
/// outside click.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: GridModel
    private let onTriggerSettingsChanged: () -> Void

    public init(model: GridModel, onTriggerSettingsChanged: @escaping () -> Void) {
        self.model = model
        self.onTriggerSettingsChanged = onTriggerSettingsChanged
        super.init()
    }

    public func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = SettingsViewModel(model: model, onTriggerSettingsChanged: onTriggerSettingsChanged)
        let hosting = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "LaunchpadNative Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 460))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        // Keep the NSWindow instance around (isReleasedWhenClosed = false)
        // so reopening doesn't rebuild the whole SwiftUI tree/view model.
    }
}
