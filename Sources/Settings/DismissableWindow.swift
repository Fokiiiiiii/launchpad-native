import AppKit

/// A borderless-looking floating window (Round 13 §A) — used by both
/// `SettingsWindowController` and `UninstallPanelWindowController` now that
/// neither shows any native titlebar chrome (traffic lights included).
/// Escape-to-close, mirroring `Sources/Launcher/LauncherWindow.swift`'s own
/// `cancelOperation` override rather than a second, differently-implemented
/// "detect Escape" mechanism living alongside the click-based
/// `OutsideClickDismissMonitor`.
final class DismissableWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
