import AppKit
import CoreGraphics
import DesignSystem
import Diagnostics
import SwiftUI

/// Presents the "What's New" panel — same runtime structure as
/// `Settings.SettingsWindowController`/`UninstallPanelWindowController`
/// (window level above the Dock, `collectionBehavior` matching
/// `LauncherWindow`, outside-click-dismiss, key-reclaim handshake on close)
/// rather than `Onboarding`'s simpler standalone-centered-window pattern —
/// this panel appears *over* an already-visible launcher, not in place of
/// one, so it needs the same "float above, hand key status back on close"
/// mechanics those two already have.
@MainActor
public final class WhatsNewWindowController: NSObject, NSWindowDelegate {
    private var window: DismissableWindow?
    /// See `SettingsWindowController.onWillClose`'s doc comment for why this
    /// exists at all — identical reasoning applies here.
    private let dismissal: PanelDismissal

    public init(onWillClose: @escaping () -> Void = {}) {
        self.dismissal = PanelDismissal(onWillClose: onWillClose)
        super.init()
    }

    public func show(version: String, features: [WhatsNewFeature], on screen: NSScreen?) {
        close()

        let hosting = NSHostingController(
            rootView: WhatsNewView(
                version: version,
                features: features,
                onContinue: { [weak self] in self?.close() },
                onClose: { [weak self] in self?.close() }
            )
        )
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        let background = GlassSurfaceFactory.makeCardBackground(
            cornerRadius: PanelCorner.radius(beforeMacOS27: 22),
            borderAlpha: 0.13,
            shadowOpacity: 0.60,
            shadowRadius: 55,
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
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Content is intrinsically sized by SwiftUI (fixed 640pt width,
        // height driven by the 3-row content) — let Auto Layout settle it
        // once, then read back the fitted size for the window frame.
        containerController.view.layoutSubtreeIfNeeded()
        let fittingSize = hosting.view.fittingSize
        window.setContentSize(fittingSize)
        PanelPlacement.center(window, on: screen)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        dismissal.startMonitoring(panelWindow: window) { [weak self] in
            DiagnosticsLog.whatsNew.info("what's new panel: dismissed by a click outside it")
            self?.close()
        }
    }

    public func close() {
        dismissal.stopMonitoring()
        window?.close()
        window = nil
    }

    /// See `SettingsWindowController.closeWithoutKeyReclaim()`'s doc comment
    /// for the exact race this avoids (identical reasoning applies here).
    public func closeWithoutKeyReclaim() {
        dismissal.suppressNextKeyReclaim()
        close()
    }

    public func windowWillClose(_ notification: Notification) {
        dismissal.windowWillClose()
    }

}
