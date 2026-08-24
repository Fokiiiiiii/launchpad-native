import AppKit
import CoreGraphics
import DesignSystem
import Diagnostics
import Grid
import Persistence
import SwiftUI

enum SettingsWindowMetrics {
    // The design reference's card is 400pt wide. A 360pt card keeps the same
    // hierarchy at a compact scale while leaving enough width for localized
    // labels; rows grow vertically when a Dynamic Type size needs more room.
    static let width: CGFloat = 360
    static let height: CGFloat = 480
    static let size = NSSize(width: width, height: height)
}

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
    private let dismissal: PanelDismissal
    /// Built once, alongside the window, and kept alive for the controller's
    /// lifetime.
    private var viewModel: SettingsViewModel?
    /// Closes Settings on a click outside its bounds (Round 12 §7) — the
    /// launcher itself must never react to that same click, see
    /// `OutsideClickDismissMonitor`'s doc comment.
    /// Round 13 §A: set by `closeWithoutKeyReclaim()` right before closing
    /// — see that method's doc comment for the race it exists to avoid.

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
        self.dismissal = PanelDismissal(onWillClose: onWillClose)
        super.init()
    }

    public func show(on screen: NSScreen?) {
        if let window {
            viewModel?.refresh()
            PanelPlacement.center(window, on: screen)
            dismissal.startMonitoring(panelWindow: window) { [weak window] in
                DiagnosticsLog.settings.info("settings panel: dismissed by a click outside it")
                window?.close()
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
        hosting.view.appearance = NSAppearance(named: .darkAqua)

        let root = NSView(frame: NSRect(origin: .zero, size: SettingsWindowMetrics.size))
        let background = GlassSurfaceFactory.makeCardBackground(
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
        window.title = ""
        window.styleMask = [.borderless]
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.setContentSize(SettingsWindowMetrics.size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        PanelPlacement.center(window, on: screen)
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

        dismissal.startMonitoring(panelWindow: window) { [weak window] in
            DiagnosticsLog.settings.info("settings panel: dismissed by a click outside it")
            window?.close()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        dismissal.windowWillClose()
    }

    /// Closes Settings if it's open — a no-op otherwise. Used by the
    /// composition root to enforce mutual exclusivity with the Uninstall
    /// panel (Round 12 §7): opening one closes the other first.
    public func close() {
        window?.close()
    }

    public func closeWithoutKeyReclaim() {
        dismissal.suppressNextKeyReclaim()
        window?.close()
    }

    public func debugClose() {
        close()
    }
}
