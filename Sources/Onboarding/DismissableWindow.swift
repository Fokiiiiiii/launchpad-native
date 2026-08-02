import AppKit

/// `Onboarding`-module-local duplicate of `Settings.DismissableWindow`.
/// Needed here specifically because Round 20 hides the native titlebar
/// close button (to match Settings/Uninstall/What's New's chrome-less
/// look) — without this, there would be no way to dismiss the wizard early
/// at all. Escape mirrors `Sources/Launcher/LauncherWindow.swift`'s own
/// `cancelOperation` override.
final class DismissableWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
