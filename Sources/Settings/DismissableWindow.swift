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

    // Borderless Liquid Glass panels have no native titlebar to grant key
    // status. Keep the same keyboard and control behavior as the old titled
    // panel after the chrome is removed.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "w" else {
            return super.performKeyEquivalent(with: event)
        }
        onCancel?()
        return true
    }
}
