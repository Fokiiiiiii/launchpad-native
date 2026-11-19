import Foundation

/// Pure classification of a raw `NX_SYSDEFINED` special-key event, kept free
/// of `CGEventTap`/`NSEvent` so the bit-packing logic is unit-testable.
/// Verified on real hardware:
/// `NX_KEYTYPE_LAUNCH_PANEL = 13`, subtype `NX_SUBTYPE_AUX_CONTROL_BUTTONS = 8`,
/// `data1` packs `(keyCode << 16) | keyFlags` where `keyFlags` bit 8 is the
/// down/up state and bit 0 is the auto-repeat flag.
import CLaunchpadCore

public struct F4KeyEvent: Equatable, Sendable {
    public let keyCode: Int
    public let isKeyDown: Bool
    public let isRepeat: Bool
}

public enum F4EventClassifier {
    public static let auxControlButtonsSubtype = 8
    public static let launchPanelKeyCode = 13

    public static func classify(subtype: Int, data1: Int) -> F4KeyEvent? {
        let encoded = launchpad_classify_special_key(Int64(subtype), Int64(data1))
        guard encoded >= 0 else { return nil }
        return F4KeyEvent(
            keyCode: Int(encoded & 0xffff),
            isKeyDown: encoded & (1 << 16) != 0,
            isRepeat: encoded & (1 << 17) != 0
        )
    }

    /// The only transition that should toggle the launcher: a fresh (non-repeat)
    /// key-down of the Launch Panel key. Key-up and auto-repeat are ignored so
    /// holding F4 doesn't toggle repeatedly.
    public static func isLaunchPanelActivation(_ event: F4KeyEvent) -> Bool {
        event.keyCode == launchPanelKeyCode && event.isKeyDown && !event.isRepeat
    }
}
