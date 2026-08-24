import AppKit
import DesignSystem
import Foundation
import Testing
@testable import Settings

@Test("settings window stays close to the compact design reference")
func settingsWindowUsesCompactMetrics() {
    #expect(SettingsWindowMetrics.width == 360)
    #expect(SettingsWindowMetrics.height == 480)
    #expect(SettingsWindowMetrics.size == CGSize(width: 360, height: 480))
}

@Test @MainActor func commandWClosesBorderlessSettingsWindows() {
    let window = DismissableWindow(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    var closed = false
    window.onCancel = { closed = true }
    let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "w",
        charactersIgnoringModifiers: "w",
        isARepeat: false,
        keyCode: 13
    )

    #expect(event.map(window.performKeyEquivalent) == true)
    #expect(closed)
}
