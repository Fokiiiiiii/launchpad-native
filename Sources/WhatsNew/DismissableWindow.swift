import AppKit

/// `WhatsNew`-module-local duplicate of `Settings.DismissableWindow` — same
/// Escape-to-close behavior, mirroring `Sources/Launcher/LauncherWindow.swift`'s
/// own `cancelOperation` override. See `WhatsNewGlassBackground.swift`'s doc
/// comment for why this module keeps its own small copies instead of
/// depending on `Settings`.
final class DismissableWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
