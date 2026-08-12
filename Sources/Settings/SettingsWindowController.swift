import AppKit
import CoreGraphics
import Grid
import Persistence
import SwiftUI

enum SettingsWindowMetrics {
    // Tessera's reference card is 400pt wide. A 360pt card keeps the same
    // hierarchy at a compact scale while leaving enough width for localized
    // labels; rows grow vertically when a Dynamic Type size needs more room.
    static let width: CGFloat = 360
    static let height: CGFloat = 480
    static let size = NSSize(width: width, height: height)
}

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
    private var window: DismissableWindow?
    private let model: GridModel
    /// Re-applies trigger settings to the live `TriggerCoordinator` and
    /// returns whether F4 actually activated — so the Triggers tab can tell
    /// "enabled but missing Input Monitoring permission" apart from
    /// "genuinely working," not just record what the user asked for.
    private let onTriggerSettingsChanged: (TriggerSettings) async -> TriggerSettingsApplyResult
    /// Re-applies the Hide Dock preference to the live `LauncherWindow`
    /// immediately — `GridModel` alone can persist the setting, but only
    /// `LauncherWindowController` (which owns the actual window) can update
    /// its live `level`.
    private let onDockVisibilityChanged: (Bool) -> Void
    private let onShowsMenuBarIconChanged: (Bool) -> Void
    private let onAppIconStyleChanged: (AppIconStyle) -> Void
    private let onShowsHiddenAppsInSearchChanged: () -> Void
    private let onMenuBarApplicationsChanged: () -> Void
    private let onBackgroundSettingsChanged: () -> Void
    private let onCustomSourcesChanged: () -> Void
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
    /// Round 13 §A: set by `closeWithoutKeyReclaim()` right before closing
    /// — see that method's doc comment for the race it exists to avoid.
    private var suppressNextWillCloseReclaim = false

    public init(
        model: GridModel,
        onTriggerSettingsChanged: @escaping (TriggerSettings) async -> TriggerSettingsApplyResult,
        onDockVisibilityChanged: @escaping (Bool) -> Void,
        onShowsMenuBarIconChanged: @escaping (Bool) -> Void = { _ in },
        onAppIconStyleChanged: @escaping (AppIconStyle) -> Void = { _ in },
        onShowsHiddenAppsInSearchChanged: @escaping () -> Void = {},
        onMenuBarApplicationsChanged: @escaping () -> Void = {},
        onBackgroundSettingsChanged: @escaping () -> Void = {},
        onCustomSourcesChanged: @escaping () -> Void = {},
        onWillClose: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onTriggerSettingsChanged = onTriggerSettingsChanged
        self.onDockVisibilityChanged = onDockVisibilityChanged
        self.onShowsMenuBarIconChanged = onShowsMenuBarIconChanged
        self.onAppIconStyleChanged = onAppIconStyleChanged
        self.onShowsHiddenAppsInSearchChanged = onShowsHiddenAppsInSearchChanged
        self.onMenuBarApplicationsChanged = onMenuBarApplicationsChanged
        self.onBackgroundSettingsChanged = onBackgroundSettingsChanged
        self.onCustomSourcesChanged = onCustomSourcesChanged
        self.onWillClose = onWillClose
        super.init()
    }

    /// - Parameter screen: the launcher's own current screen (Round 13 §A)
    ///   — Settings centers on it instead of `NSWindow.center()`'s main-
    ///   screen default, which has no relationship to where the launcher
    ///   itself is actually showing on a multi-display setup. Recomputed
    ///   on *every* call, even when the window already exists — otherwise a
    ///   kept-alive Settings window reopens at a stale position if the
    ///   launcher moved to a different screen since it was last shown.
    public func show(on screen: NSScreen?) {
        if let window {
            viewModel?.refresh()
            positionWindow(window, on: screen)
            if outsideClickMonitor == nil {
                let monitor = OutsideClickDismissMonitor(panelWindow: window) { [weak window] in
                    window?.close()
                }
                monitor.start()
                outsideClickMonitor = monitor
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = SettingsViewModel(
            model: model,
            onTriggerSettingsChanged: onTriggerSettingsChanged,
            onDockVisibilityChanged: onDockVisibilityChanged,
            onShowsMenuBarIconChanged: onShowsMenuBarIconChanged,
            onAppIconStyleChanged: onAppIconStyleChanged,
            onShowsHiddenAppsInSearchChanged: onShowsHiddenAppsInSearchChanged,
            onMenuBarApplicationsChanged: onMenuBarApplicationsChanged,
            onBackgroundSettingsChanged: onBackgroundSettingsChanged,
            onCustomSourcesChanged: onCustomSourcesChanged
        )
        viewModel.refreshF4Status()
        self.viewModel = viewModel
        let hosting = NSHostingController(
            rootView: SettingsView(viewModel: viewModel, onClose: { [weak self] in self?.close() })
                .environment(\.colorScheme, .dark)
        )
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        // The card uses a fixed dark Liquid Glass tint to match Tessera. Keep
        // AppKit and SwiftUI on the same appearance so adaptive `.primary`
        // and `.secondary` text never resolve to dark ink on the dark card in
        // macOS Light appearance.
        hosting.view.appearance = NSAppearance(named: .darkAqua)

        // Round 20: real glass-card chrome behind the SwiftUI content,
        // matching the reference — same `root`/`background`/`hosting.view`
        // sibling pattern `LauncherWindow.swift` already establishes
        // (`makeWindow(on:)`, lines ~447-481). Reuses `Grid`'s own
        // `makeFolderCardBackground` recipe (already value-matched to the
        // reference's small-card material) rather than inventing a second
        // one — `Settings` already depends on `Grid` per `Package.swift`.
        let root = NSView(frame: NSRect(origin: .zero, size: SettingsWindowMetrics.size))
        let background = GlassBackgroundHelper.makeFolderCardBackground(
            cornerRadius: 13,
            tint: NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.86),
            borderAlpha: 0.12,
            shadowOpacity: 0.66,
            shadowRadius: 50,
            shadowOffset: CGSize(width: 0, height: -27)
        )
        background.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(background)
        root.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: root.topAnchor),
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            hosting.view.topAnchor.constraint(equalTo: root.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        let containerController = NSViewController()
        containerController.view = root

        let window = DismissableWindow(contentViewController: containerController)
        window.onCancel = { [weak self] in self?.close() }
        // Round 13 §A: no native chrome at all — the reference is a
        // borderless floating card, so avoid reserving an invisible titlebar
        // region above the SwiftUI tabs. `DismissableWindow` explicitly keeps
        // key status for toggles, pickers, and keyboard dismissal.
        window.title = ""
        window.styleMask = [.borderless]
        window.isMovableByWindowBackground = true
        // Round 20: the glass card itself now draws the window's visible
        // shape/shadow — the window frame must be transparent/shadowless
        // so it doesn't composite a second, square, opaque layer behind
        // the rounded card (same trio `LauncherWindow.swift` already uses).
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.setContentSize(SettingsWindowMetrics.size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        positionWindow(window, on: screen)
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

    private func positionWindow(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else {
            window.center()
            return
        }
        let target = screen.visibleFrame
        let origin = NSPoint(
            x: target.midX - window.frame.width / 2,
            y: target.midY - window.frame.height / 2
        )
        window.setFrameOrigin(origin)
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
    /// The launcher is now a fullscreen primary window, but the same explicit
    /// reclaim remains necessary when a panel temporarily owns key status.
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
        let shouldReclaim = !suppressNextWillCloseReclaim
        suppressNextWillCloseReclaim = false
        guard shouldReclaim else { return }
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

    /// Round 13 §A: used specifically when the *launcher itself* is hiding
    /// (`LauncherWindowController.onDidHide`) — `hide()` fades the launcher
    /// out over ~0.3s and only calls `orderOut` (flipping `isVisible` to
    /// `false`) once that completes, but `windowWillClose`'s `onWillClose`
    /// fires on the *next run-loop turn*, well before that fade finishes.
    /// A plain `close()` here would call `reclaimKeyIfVisible()` while the
    /// launcher's `window.isVisible` is still `true` — if the launcher is
    /// hiding because the user switched to a *different* app, this would
    /// force-reactivate LaunchpadNative and steal focus back moments after
    /// the user deliberately switched away. There's nothing to reclaim onto
    /// in this case anyway (the launcher is also on its way out), so this
    /// entry point skips the handshake entirely.
    public func closeWithoutKeyReclaim() {
        suppressNextWillCloseReclaim = true
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
