import Foundation

/// Pure classification of a raw `NX_SYSDEFINED` special-key event, kept free
/// of `CGEventTap`/`NSEvent` so the bit-packing logic is unit-testable.
/// Verified against `ReverseEngineering/Contracts/f4-hid.md`:
/// `NX_KEYTYPE_LAUNCH_PANEL = 13`, subtype `NX_SUBTYPE_AUX_CONTROL_BUTTONS = 8`,
/// `data1` packs `(keyCode << 16) | keyFlags` where `keyFlags` bit 8 is the
/// down/up state and bit 0 is the auto-repeat flag.
public struct F4KeyEvent: Equatable, Sendable {
    public let keyCode: Int
    public let isKeyDown: Bool
    public let isRepeat: Bool
}

public enum F4EventClassifier {
    public static let auxControlButtonsSubtype = 8
    public static let launchPanelKeyCode = 13

    public static func classify(subtype: Int, data1: Int) -> F4KeyEvent? {
        guard subtype == auxControlButtonsSubtype else { return nil }
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let keyRepeat = (keyFlags & 0x1) != 0
        return F4KeyEvent(keyCode: keyCode, isKeyDown: keyState == 1, isRepeat: keyRepeat)
    }

    /// The only transition that should toggle the launcher: a fresh (non-repeat)
    /// key-down of the Launch Panel key. Key-up and auto-repeat are ignored so
    /// holding F4 doesn't toggle repeatedly.
    public static func isLaunchPanelActivation(_ event: F4KeyEvent) -> Bool {
        event.keyCode == launchPanelKeyCode && event.isKeyDown && !event.isRepeat
    }
}
