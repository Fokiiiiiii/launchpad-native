import AppKit
import Catalog
import CoreGraphics
import SwiftUI

/// Presents the new Uninstall panel (Round 12 §6) — a small floating window
/// over the still-visible launcher, same level/collectionBehavior/outside-
/// click-dismiss mechanics as `SettingsWindowController`, but rebuilt fresh
/// per target app (unlike Settings, which is a singleton-ish always-same-
/// view-model window) since each Uninstall request targets a different
/// `ApplicationRecord`.
@MainActor
public final class UninstallPanelWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let iconCache: IconCache
    private var outsideClickMonitor: OutsideClickDismissMonitor?
    private var viewModel: UninstallPanelViewModel?

    public init(iconCache: IconCache) {
        self.iconCache = iconCache
        super.init()
    }

    public func show(for record: ApplicationRecord, allRecords: [ApplicationRecord]) {
        close()

        let viewModel = UninstallPanelViewModel(record: record, allRecords: allRecords)
        self.viewModel = viewModel

        let hosting = NSHostingController(
            rootView: UninstallPanelView(
                viewModel: viewModel,
                appIcon: nil,
                onCancel: { [weak self] in self?.close() },
                onConfirm: { [weak self] in self?.confirmAndClose() }
            )
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 420, height: 480))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        // Same stacking as SettingsWindowController — above the Dock (and
        // therefore above LauncherWindow) so it renders over the still-
        // visible launcher grid instead of behind it.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let monitor = OutsideClickDismissMonitor(panelWindow: window) { [weak self] in self?.close() }
        monitor.start()
        outsideClickMonitor = monitor

        let cache = iconCache
        Task { [weak self] in
            let icon = await cache.icon(for: record, size: 48)
            guard let self, self.viewModel === viewModel else { return } // stale request guard
            let updatedHosting = NSHostingController(
                rootView: UninstallPanelView(
                    viewModel: viewModel,
                    appIcon: icon,
                    onCancel: { [weak self] in self?.close() },
                    onConfirm: { [weak self] in self?.confirmAndClose() }
                )
            )
            self.window?.contentViewController = updatedHosting
        }
    }

    private func confirmAndClose() {
        viewModel?.confirmMoveToTrash()
        close()
    }

    public func close() {
        outsideClickMonitor?.stop()
        outsideClickMonitor = nil
        window?.close()
        window = nil
        viewModel = nil
    }

    public func windowWillClose(_ notification: Notification) {
        outsideClickMonitor?.stop()
        outsideClickMonitor = nil
    }
}
