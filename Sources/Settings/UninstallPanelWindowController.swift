import AppKit
import Catalog
import CoreGraphics
import DesignSystem
import Diagnostics
import Foundation
import Grid
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
    private let dismissal: PanelDismissal
    private var viewModel: UninstallPanelViewModel?
    /// Round 20 §C: the sibling `background`/`hosting.view` pair inside the
    /// window's real content view. Kept as stored properties (rather than
    /// rebuilding them each time) because the async icon-fetch completion
    /// below must swap in a new hosting view *without* discarding this
    /// `root`/`background` pair — replacing `window.contentViewController`
    /// wholesale (the pre-Round-20 approach) would tear down the glass card
    /// along with it.
    private var rootContentView: NSView?
    private var currentHostingView: NSView?
    /// Round 13 §A: set by `closeWithoutKeyReclaim()` — see
    /// `SettingsWindowController.closeWithoutKeyReclaim()`'s doc comment for
    /// the race this avoids (identical reasoning applies here).
    /// Guards the destructive action while its operation report is being
    /// persisted. A report-write failure leaves the panel open so its warning
    /// can be read; the model itself also rejects any second execution.
    private var isConfirming = false

    public init(iconCache: IconCache, onWillClose: @escaping () -> Void = {}) {
        self.iconCache = iconCache
        self.dismissal = PanelDismissal(onWillClose: onWillClose)
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
                onConfirm: { [weak self] in self?.confirmAndClose() },
                onContentHeightChange: { [weak self] height in self?.applyContentHeight(height) }
            )
        )
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        // Round 20 §C: same `root`/`background`/`hosting.view` sibling glass
        // chrome as `SettingsWindowController.show(on:)` — see that method's
        // doc comment for why the background is a sibling rather than a
        // container. Both are kept as stored properties (`rootContentView`/
        // `currentHostingView`) because the icon-fetch completion below must
        // replace only the hosting view, not this whole hierarchy.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 586, height: 500))
        let background = GlassSurfaceFactory.makeCardBackground(
            cornerRadius: 13,
            tint: NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 32 / 255, alpha: 0.90),
            borderAlpha: 0.13,
            shadowOpacity: 0.70,
            shadowRadius: 55,
            shadowOffset: CGSize(width: 0, height: -31)
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
        rootContentView = root
        currentHostingView = hosting.view

        let containerController = NSViewController()
        containerController.view = root

        let window = DismissableWindow(contentViewController: containerController)
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
        // Round 20 §C: the glass card now draws the window's visible shape/
        // shadow — the window frame itself must be transparent/shadowless so
        // it doesn't composite a second, square, opaque layer behind the
        // rounded card (same trio `SettingsWindowController`/`LauncherWindow`
        // already use).
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.setContentSize(NSSize(width: 586, height: 500))
        window.isReleasedWhenClosed = false
        window.delegate = self
        PanelPlacement.center(window, on: screen)
        // Same stacking as SettingsWindowController — above the Dock (and
        // therefore above LauncherWindow) so it renders over the still-
        // visible launcher grid instead of behind it.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        dismissal.startMonitoring(panelWindow: window) { [weak self] in
            DiagnosticsLog.settings.info("uninstall panel: dismissed by a click outside it")
            self?.close()
        }

        let cache = iconCache
        Task { [weak self] in
            // Bumped from 48 to 64 (Round 13 §B) alongside the enlarged
            // header icon frame — fetching at the final display size keeps
            // it crisp instead of upscaling a smaller bitmap.
            let icon = await cache.icon(for: record, size: 64)
            guard let self, self.viewModel === viewModel, let root = self.rootContentView else { return } // stale request guard
            let updatedHosting = NSHostingController(
                rootView: UninstallPanelView(
                    viewModel: viewModel,
                    appIcon: icon,
                    onCancel: { [weak self] in self?.close() },
                    onConfirm: { [weak self] in self?.confirmAndClose() },
                    onContentHeightChange: { [weak self] height in self?.applyContentHeight(height) }
                )
            )
            updatedHosting.view.translatesAutoresizingMaskIntoConstraints = false
            // Round 20 §C: replace only the hosting view inside `root`, not
            // `window.contentViewController` itself — swapping the whole
            // content view controller (the pre-Round-20 approach) would
            // discard the `background` glass card sibling along with it.
            self.currentHostingView?.removeFromSuperview()
            root.addSubview(updatedHosting.view)
            NSLayoutConstraint.activate([
                updatedHosting.view.topAnchor.constraint(equalTo: root.topAnchor),
                updatedHosting.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                updatedHosting.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                updatedHosting.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
            self.currentHostingView = updatedHosting.view
            // Keep the container's `NSViewController` retaining the new
            // `NSHostingController` alive — `root.addSubview` alone doesn't
            // extend its lifetime beyond this closure.
            self.window?.contentViewController?.addChild(updatedHosting)
        }
    }

    /// Real, confirmed bug: the window used to be a fixed 500pt tall
    /// regardless of how much content actually fit inside it — since
    /// `ScrollView` (unlike `VStack`) always greedily claims its full
    /// allotted height rather than shrinking to short content, a real
    /// screenshot showed a large empty gap between the last visible row and
    /// the footer buttons ("消去uiの上のデッドスペース"). `UninstallPanelView`
    /// now measures its own true content height via a `GeometryReader`-
    /// backed `PreferenceKey` and reports it here — this resizes the real
    /// window to match, instead of a SwiftUI-side band-aid that can't
    /// actually shrink the `NSWindow` itself. Keeps the window's vertical
    /// *center* fixed while resizing (matching `positionWindow`'s own
    /// screen-centering) so it shrinks/grows symmetrically in place rather
    /// than sliding to a new position. A sane floor (200pt) guards against
    /// collapsing to nothing during the brief window before the first
    /// layout pass reports a real height.
    private func applyContentHeight(_ height: CGFloat) {
        guard let window else { return }
        let clampedHeight = max(height, 200)
        guard abs(window.frame.height - clampedHeight) > 0.5 else { return }
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        var newFrame = window.frame
        newFrame.size.height = clampedHeight
        newFrame.origin.y = center.y - clampedHeight / 2
        window.setFrame(newFrame, display: true, animate: true)
    }

    private func confirmAndClose() {
        guard !isConfirming, let viewModel else { return }
        isConfirming = true
        _ = viewModel.confirmMoveToTrash { [weak self, weak viewModel] reportSaved in
            guard let self, self.viewModel === viewModel else { return }
            self.isConfirming = false
            // The removal has already happened either way. Close on the
            // normal path only after the report is safely persisted; on a
            // report failure, keep the panel open so the model's warning can
            // distinguish that bookkeeping failure from the completed move.
            if reportSaved {
                self.close()
            }
        }
    }

    public func close() {
        isConfirming = false
        dismissal.stopMonitoring()
        window?.close()
        window = nil
        viewModel = nil
        rootContentView = nil
        currentHostingView = nil
    }

    /// Round 13 §A: used when the *launcher itself* is hiding — see
    /// `SettingsWindowController.closeWithoutKeyReclaim()`'s doc comment for
    /// the exact race this avoids (identical reasoning applies here).
    public func closeWithoutKeyReclaim() {
        dismissal.suppressNextKeyReclaim()
        close()
    }

    public func windowWillClose(_ notification: Notification) {
        dismissal.windowWillClose()
    }

}
