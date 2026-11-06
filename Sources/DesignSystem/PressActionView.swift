import AppKit

/// A plain container that VoiceOver can press. The grid and search cells are
/// custom views given the button role, and a button role with nothing behind
/// `AXPress` reads as pressable but does nothing; this view carries the action
/// the mouse and keyboard paths already run.
public final class PressActionView: NSView {
    public var onPress: (() -> Void)?

    public override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}
