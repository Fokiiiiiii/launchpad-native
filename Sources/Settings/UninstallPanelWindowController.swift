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
    private var window: DismissableWindow?
    private let iconCache: IconCache
    /// Fired when this window closes — same reasoning as
    /// `SettingsWindowController`'s own `onWillClose`: without it, the
    /// launcher (a `.nonactivatingPanel`) never reclaims key status on its
    /// own once this panel goes away, and every control in it stops
    /// accepting clicks/keyboard input. Round 13 §A: this was previously
    /// missing entirely for this controller (an asymmetry versus Settings),
    /// fixed here.
    private let onWillClose: () -> Void
    private var outsideClickMonitor: OutsideClickDismissMonitor?
    private var viewModel: UninstallPanelViewModel?
    /// Round 13 §A: set by `closeWithoutKeyReclaim()` — see
    /// `SettingsWindowController.closeWithoutKeyReclaim()`'s doc comment for
    /// the race this avoids (identical reasoning applies here).
    private var suppressNextWillCloseReclaim = false

    public init(iconCache: IconCache, onWillClose: @escaping () -> Void = {}) {
        self.iconCache = iconCache
        self.onWillClose = onWillClose
        super.init()
    }

    /// - Parameter screen: the launcher's own current screen (Round 13 §A) —
    ///   see `SettingsWindowController.show(on:)`'s doc comment for why.
    public func show(for record: ApplicationRecord, allRecords: [ApplicationRecord], on screen: NSScreen?) {
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
        let window = DismissableWindow(contentViewController: hosting)
        window.onCancel = { [weak self] in self?.close() }
        // Round 13 §A: no native chrome at all — same treatment as
        // `SettingsWindowController`. `titlebarAppearsTransparent` alone
        // (the prior state) still left the traffic-light buttons visible;
        // they're now force-hidden too.
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 420, height: 500))
        window.isReleasedWhenClosed = false
        window.delegate = self
        positionWindow(window, on: screen)
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
            // Bumped from 48 to 64 (Round 13 §B) alongside the enlarged
            // header icon frame — fetching at the final display size keeps
            // it crisp instead of upscaling a smaller bitmap.
            let icon = await cache.icon(for: record, size: 64)
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

    /// Round 13 §A: used when the *launcher itself* is hiding — see
    /// `SettingsWindowController.closeWithoutKeyReclaim()`'s doc comment for
    /// the exact race this avoids (identical reasoning applies here).
    public func closeWithoutKeyReclaim() {
        suppressNextWillCloseReclaim = true
        close()
    }

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
}
