import AppKit
import DesignSystem
import SwiftUI

/// Shown once, on first launch (see `OnboardingState`). A plain centered
/// window like `SettingsWindowController` — no elevated window level or
/// Space-joining needed here, since nothing else is showing yet the first
/// time this appears.
///
/// Round 20: chrome-less glass card, matching Settings/Uninstall/What's
/// New — same `root`/background/`hosting.view` sibling pattern as
/// `LauncherWindow.swift`. Hiding the native titlebar close button means
/// `DismissableWindow`'s Escape handling is now the only way to dismiss
/// this early besides clicking through all 4 pages.
@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: DismissableWindow?
    private let onFinished: () -> Void
    /// Guards against `finish()` running twice — once from the "Get
    /// Started" button, once from `windowWillClose` if the user instead
    /// dismisses via Escape.
    private var didFinish = false

    public init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        super.init()
    }

    public func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: OnboardingView(onFinished: { [weak self] in
            self?.finish()
        }))
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        let background = GlassSurfaceFactory.makeCardBackground(
            cornerRadius: 22,
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
        window.onCancel = { [weak self] in self?.finish() }
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
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window any way (the "Get Started" button, or the
    /// titlebar close button) counts as "seen" — re-showing this every
    /// single launch just because the user dismissed it via the X button
    /// instead of clicking through would be worse than not having it.
    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        OnboardingState.markCompleted()
        window?.close()
        onFinished()
    }

    public func windowWillClose(_ notification: Notification) {
        finish()
    }
}
