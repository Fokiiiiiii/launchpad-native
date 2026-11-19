import AppKit
import DesignSystem
import Foundation
import Testing
@testable import Settings

@Test("settings window has larger controls")
func settingsWindowUsesCompactMetrics() {
    #expect(SettingsWindowMetrics.width == 440)
    #expect(SettingsWindowMetrics.height == 590)
    #expect(SettingsWindowMetrics.size == CGSize(width: 440, height: 590))
}

@Test func settingsWindowFitsSmallDisplays() {
    #expect(SettingsWindowMetrics.size(fitting: CGRect(x: 0, y: 0, width: 1280, height: 560)) == CGSize(width: 440, height: 536))
    #expect(SettingsWindowMetrics.size(fitting: CGRect(x: 0, y: 0, width: 400, height: 1000)) == CGSize(width: 376, height: 590))
    #expect(SettingsWindowMetrics.size(fitting: nil) == CGSize(width: 440, height: 590))
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
