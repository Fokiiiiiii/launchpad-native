import AppKit
import Testing
@testable import DesignSystem

/// These panels hide every piece of native chrome, so the window itself is
/// the only thing left that can answer Escape and Command-W. Each module used
/// to carry its own copy of this window, and the copies had drifted — the
/// What's New and onboarding panels had lost Command-W and the key/main
/// overrides entirely. Now that there is one implementation, these pin the
/// behavior that the copies were silently missing.
@MainActor
private func makePanel() -> (DismissableWindow, () -> Int) {
    let window = DismissableWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
        styleMask: [.borderless],
        backing: .buffered,
        defer: true
    )
    // A programmatic window frees itself on close; several tests each closing
    // their own window segfaults the run.
    window.isReleasedWhenClosed = false
    final class Counter { var value = 0 }
    let counter = Counter()
    window.onCancel = { counter.value += 1 }
    return (window, { counter.value })
}

@MainActor
private func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 13
    )!
}

@Test @MainActor func escapeClosesThePanel() {
    let (window, cancels) = makePanel()
    defer { window.orderOut(nil) }
    window.cancelOperation(nil)
    #expect(cancels() == 1)
}

@Test @MainActor func commandWClosesThePanel() {
    let (window, cancels) = makePanel()
    defer { window.orderOut(nil) }
    #expect(window.performKeyEquivalent(with: keyEvent(characters: "w", modifiers: .command)))
    #expect(cancels() == 1)
}

@Test @MainActor func anUnrelatedKeyEquivalentIsLeftAlone() {
    let (window, cancels) = makePanel()
    defer { window.orderOut(nil) }
    _ = window.performKeyEquivalent(with: keyEvent(characters: "w", modifiers: []))
    _ = window.performKeyEquivalent(with: keyEvent(characters: "n", modifiers: .command))
    #expect(cancels() == 0)
}

/// A borderless window is not key-eligible by default, and these panels host
/// text fields and controls.
@Test @MainActor func aBorderlessPanelCanStillBecomeKeyAndMain() {
    let (window, _) = makePanel()
    defer { window.orderOut(nil) }
    #expect(window.canBecomeKey)
    #expect(window.canBecomeMain)
}

/// Placement follows the screen the launcher is on, not AppKit's idea of the
/// main screen — and must not crash when there is no screen to aim at.
@Test @MainActor func centeringPlacesThePanelInTheVisibleFrame() throws {
    let screen = try #require(NSScreen.main)
    let (window, _) = makePanel()
    defer { window.orderOut(nil) }
    PanelPlacement.center(window, on: screen)
    let visible = screen.visibleFrame
    #expect(abs(window.frame.midX - visible.midX) < 1)
    #expect(abs(window.frame.midY - visible.midY) < 1)
}

/// An app icon is a rounded square drawn inside a canvas that leaves a margin
/// around it — the artwork is 824 of the canvas's 1024 points. An image view
/// is sized to the canvas, so a tile measured from the view's own frame is far
/// larger than it looks against the icon anyone sees; at this grid's sizes it
/// overran the cell and clipped against the row above.
@Test @MainActor func theSelectionTileIsMeasuredFromTheArtworkNotTheCanvas() {
    let canvas: CGFloat = 100
    let tile = SelectionHighlight.tileGeometry(iconViewSide: canvas)
    let side = canvas - tile.inset * 2
    let artwork = canvas * 824 / 1024

    #expect(side > artwork, "the tile did not clear the artwork")
    #expect(side < artwork * 1.35, "the tile was far larger than the artwork")
    #expect(side < canvas * 1.1, "the tile would overrun the cell")
    #expect(tile.cornerRadius > side * 0.15)
    #expect(tile.cornerRadius < side * 0.3)
}

/// The tile has to scale with the icon: the grid's icon size follows the row
/// and column counts, so a fixed inset is right at one setting and wrong at
/// every other.
@Test @MainActor func theTileScalesWithTheIcon() {
    let small = SelectionHighlight.tileGeometry(iconViewSide: 60)
    let large = SelectionHighlight.tileGeometry(iconViewSide: 180)
    let smallSide = 60 - small.inset * 2
    let largeSide = 180 - large.inset * 2
    #expect(abs(largeSide / smallSide - 3) < 0.01, "the tile did not scale with the icon")
    #expect(abs(large.cornerRadius / small.cornerRadius - 3) < 0.01)
}
