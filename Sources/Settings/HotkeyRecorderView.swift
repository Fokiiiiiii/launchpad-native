import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A standard macOS shortcut-recorder control: click it, press a key combo,
/// and it captures that combo — the same interaction pattern System
/// Settings' own keyboard shortcut pickers use.
///
/// `GlobalHotkeyTrigger` (`Sources/Triggers/GlobalHotkeyTrigger.swift`)
/// registers via Carbon's `RegisterEventHotKey`, which expects **Carbon**
/// modifier bits (`cmdKey`/`optionKey`/`controlKey`/`shiftKey`), not
/// `NSEvent.ModifierFlags`'s bit positions — those are different constants,
/// and `TriggerCoordinator`/`TriggerSettings.hotkeyModifierFlags` pass
/// whatever's stored straight through with no conversion. So capture must
/// convert here, once, rather than leaking that detail into every caller.
final class HotkeyRecorderNSView: NSView {
    var onCapture: ((UInt16, UInt) -> Void)?
    private(set) var isRecording = false {
        didSet { needsDisplay = true }
    }
    var displayText: String = "Click to record" {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let background = isRecording ? NSColor.selectedControlColor : NSColor.controlColor
        background.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()

        let text = isRecording ? "Press a key combo…" : displayText
        let color: NSColor = isRecording ? .selectedControlTextColor : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(at: origin, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        isRecording = false
        let carbonModifiers = Self.carbonModifiers(from: event.modifierFlags)
        onCapture?(event.keyCode, carbonModifiers)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt {
        var carbon: UInt = 0
        if flags.contains(.command) { carbon |= UInt(cmdKey) }
        if flags.contains(.option) { carbon |= UInt(optionKey) }
        if flags.contains(.control) { carbon |= UInt(controlKey) }
        if flags.contains(.shift) { carbon |= UInt(shiftKey) }
        return carbon
    }

    /// Human-readable combo string (e.g. "⌥Space") for display only —
    /// covers the common keys a global launcher shortcut would realistically
    /// use; anything else falls back to "Key <code>" rather than guessing.
    static func displayString(keyCode: UInt16?, carbonModifiers: UInt) -> String {
        guard let keyCode else { return "Click to record" }
        var symbols = ""
        if carbonModifiers & UInt(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt(cmdKey) != 0 { symbols += "⌘" }
        return symbols + keyName(for: keyCode)
    }

    private static func keyName(for keyCode: UInt16) -> String {
        let names: [UInt16: String] = [
            49: "Space", 36: "Return", 48: "Tab", 53: "Escape", 51: "Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}

/// SwiftUI bridge for `HotkeyRecorderNSView`.
struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var keyCode: UInt16?
    @Binding var carbonModifiers: UInt

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onCapture = { keyCode, modifiers in
            self.keyCode = keyCode
            self.carbonModifiers = modifiers
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.displayText = HotkeyRecorderNSView.displayString(keyCode: keyCode, carbonModifiers: carbonModifiers)
    }
}
