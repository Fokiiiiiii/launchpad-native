import AppKit

/// `WhatsNew`-module-local duplicate of `Settings.DismissableWindow` — same
/// Escape-to-close behavior, mirroring `Sources/Launcher/LauncherWindow.swift`'s
/// own `cancelOperation` override. The panel surface is provided by the
/// shared DesignSystem target.
final class DismissableWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
