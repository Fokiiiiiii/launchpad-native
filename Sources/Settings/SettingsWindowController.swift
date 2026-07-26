import AppKit
import CoreGraphics
import Grid
import SwiftUI

/// A normal (non-panel) window — unlike the launcher, Settings should behave
/// like an ordinary Mac preferences window: it can be the key/main window
/// and stays open across Spaces switches. It *does* auto-dismiss on a click
/// outside its bounds (Round 12 §7, via `OutsideClickDismissMonitor`) —
/// added on top of the titlebar close button, not instead of it — matching
/// the reference design where clicking the still-visible launcher grid
/// behind Settings closes just the panel, never the launcher itself.
///
/// It does, however, float *above* the launcher rather than behind it:
/// `LauncherWindowController` used to call `hide()` before ever opening
/// Settings, which is why the grid always disappeared first. That's been
/// removed — the launcher now stays visible underneath, matching reference
/// apps where a floating preferences panel sits over the still-visible
/// grid. For that to actually render correctly (not just *not hide* the
/// launcher while an invisible-behind-it Settings window sits underneath),
/// this window's `level` must be above `LauncherWindow`'s own
/// (`CGWindowLevelForKey(.dockWindow) - 1`) and its `collectionBehavior`
/// must match closely enough to appear on whatever Space/fullscreen state
/// the launcher is currently in.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: GridModel
    /// Re-applies trigger settings to the live `TriggerCoordinator` and
    /// returns whether F4 actually activated — so the Triggers tab can tell
    /// "enabled but missing Input Monitoring permission" apart from
    /// "genuinely working," not just record what the user asked for.
    private let onTriggerSettingsChanged: () -> Bool
    /// Re-applies the Hide Dock preference to the live `LauncherWindow`
    /// immediately — `GridModel` alone can persist the setting, but only
    /// `LauncherWindowController` (which owns the actual window) can update
    /// its live `level`.
    private let onDockVisibilityChanged: (Bool) -> Void
    /// Fired when this window closes — lets the composition root hand key
    /// status back to the still-visible launcher underneath (see
    /// `windowWillClose`'s doc comment for why this is needed at all).
    private let onWillClose: () -> Void
    /// Built once, alongside the window, and kept alive for the controller's
    /// lifetime.
    private var viewModel: SettingsViewModel?
    /// Closes Settings on a click outside its bounds (Round 12 §7) — the
    /// launcher itself must never react to that same click, see
    /// `OutsideClickDismissMonitor`'s doc comment.
    private var outsideClickMonitor: OutsideClickDismissMonitor?

    public init(
        model: GridModel,
        onTriggerSettingsChanged: @escaping () -> Bool,
        onDockVisibilityChanged: @escaping (Bool) -> Void,
        onWillClose: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onTriggerSettingsChanged = onTriggerSettingsChanged
        self.onDockVisibilityChanged = onDockVisibilityChanged
        self.onWillClose = onWillClose
        super.init()
    }

    public func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = SettingsViewModel(model: model, onTriggerSettingsChanged: onTriggerSettingsChanged, onDockVisibilityChanged: onDockVisibilityChanged)
        viewModel.refreshF4Status()
        self.viewModel = viewModel
        let hosting = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "LaunchpadNative Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 620, height: 600))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        // One level above the Dock — and therefore above `LauncherWindow`
        // (`dockLevel - 1`) too — so Settings renders in front of the still-
        // visible launcher grid instead of behind it. `.canJoinAllSpaces`/
        // `.fullScreenAuxiliary` mirror `LauncherWindow`'s own
        // `collectionBehavior` so Settings can actually appear over the
        // launcher regardless of which Space or fullscreen state it's in.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let monitor = OutsideClickDismissMonitor(panelWindow: window) { [weak window] in window?.close() }
        monitor.start()
        outsideClickMonitor = monitor
    }

    /// Keeps the NSWindow instance around (isReleasedWhenClosed = false) so
    /// reopening doesn't rebuild the whole SwiftUI tree/view model.
    ///
    /// Also notifies `onWillClose` — real, confirmed regression: since
    /// `LauncherWindowController` stopped calling `hide()` before opening
    /// Settings (so the grid stays visible underneath, matching reference
    /// apps), closing Settings left the still-visible `LauncherWindow`
    /// with no key window at all. `LauncherWindow` is an `NSPanel` with
    /// `.nonactivatingPanel` style — AppKit's automatic "hand key status to
    /// the next window" behavior on a window closing does not pick those
    /// back up the way it would an ordinary window, so nothing reclaims it
    /// automatically. The visible symptom: the search field (and every
    /// other control) stops accepting clicks/keyboard input entirely after
    /// Settings is closed, even though the launcher is still on screen.
    ///
    /// `onWillClose` is dispatched to the *next* run-loop turn, not called
    /// synchronously here — confirmed via the `LAUNCHPAD_DEBUG_SETTINGS_
    /// KEY_RECLAIM` hook that calling it synchronously doesn't stick:
    /// `windowWillClose` fires partway through `NSWindow.close()`'s own
    /// teardown (ordering out, resigning key), which continues running
    /// *after* this delegate method returns — a `makeKeyAndOrderFront`
    /// called here gets silently overwritten moments later when that
    /// teardown finishes resigning key status with nothing to reassign it
    /// to. Deferring to `DispatchQueue.main.async` lets `close()` finish
    /// completely first, so the reclaim has the last word.
    public func windowWillClose(_ notification: Notification) {
        outsideClickMonitor?.stop()
        outsideClickMonitor = nil
        DispatchQueue.main.async { [weak self] in
            self?.onWillClose()
        }
    }

    /// Closes Settings if it's open — a no-op otherwise. Used by the
    /// composition root to enforce mutual exclusivity with the Uninstall
    /// panel (Round 12 §7): opening one closes the other first.
    public func close() {
        window?.close()
    }

    /// Debug-only — see `AppDelegate`'s `LAUNCHPAD_DEBUG_SETTINGS_KEY_RECLAIM`
    /// doc comment: lets the "launcher regains key status when Settings
    /// closes" fix be exercised end-to-end via `log stream`, without
    /// Accessibility/GUI-scripting permission to actually click the close
    /// button.
    public func debugClose() {
        close()
    }
}
