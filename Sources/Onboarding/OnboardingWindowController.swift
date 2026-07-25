import AppKit
import SwiftUI

/// Shown once, on first launch (see `OnboardingState`). A plain centered
/// window like `SettingsWindowController` — no elevated window level or
/// Space-joining needed here, since nothing else is showing yet the first
/// time this appears.
@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onFinished: () -> Void
    /// Guards against `finish()` running twice — once from the "Get
    /// Started" button, once from `windowWillClose` if the user instead
    /// closes the window via its titlebar button.
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
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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
