import AppKit
import Testing
@testable import Grid

@Test @MainActor func pageControlChevronsTrackPageBoundariesAndAccessibility() {
    let control = PageControlView(frame: .zero)
    control.numberOfPages = 3
    // Not `control.subviews`: on macOS 27 the buttons live inside the glass.
    let buttons = control.buttonsForTesting
    #expect(control.dotButtonCountForTesting == 3)
    #expect(buttons.count == 5, "one chevron on each side of the three dots")
    guard buttons.count == 5 else { return }
    let previous = buttons[0]
    let next = buttons[4]

    #expect(previous.isHidden == false)
    #expect(next.isHidden == false)
    #expect(previous.isEnabled == false)
    #expect(next.isEnabled == true)
    #expect(previous.isAccessibilityEnabled() == previous.isEnabled)
    #expect(next.isAccessibilityEnabled() == next.isEnabled)

    control.currentPage = 2
    #expect(previous.isEnabled == true)
    #expect(next.isEnabled == false)
    #expect(previous.isAccessibilityEnabled() == previous.isEnabled)
    #expect(next.isAccessibilityEnabled() == next.isEnabled)

    control.numberOfPages = 1
    #expect(previous.isHidden)
    #expect(next.isHidden)
    #expect(previous.isEnabled == false)
    #expect(next.isEnabled == false)
}

/// Regression: dots are only built by `numberOfPages`'s `didSet`, which Swift
/// does not run for the property's initial value. A single-page grid assigns
/// the same value the property already holds, so with a
/// `guard numberOfPages != oldValue` in that setter and no initial build, the
/// control would show no dots at all.
@Test @MainActor func pageControlShowsADotForASinglePageGrid() {
    let control = PageControlView(frame: .zero)
    let dotsBeforeAssignment = control.dotButtonCountForTesting
    #expect(dotsBeforeAssignment == 1)

    control.numberOfPages = 1
    #expect(control.dotButtonCountForTesting == 1)

    control.numberOfPages = 4
    #expect(control.dotButtonCountForTesting == 4)

    control.numberOfPages = 1
    #expect(control.dotButtonCountForTesting == 1)
}

/// On macOS 27 the glass pill contains the buttons so it can respond to them;
/// earlier it sits behind them. Either way a click on a button must land on
/// that button — glass taking clicks meant for the controls above it is a
/// failure this project has chased before.
@Test @MainActor func everyPageControlButtonStaysClickableOnItsGlass() throws {
    let window = NSWindow(
        contentRect: NSRect(x: -30_000, y: -30_000, width: 480, height: 200),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
    window.contentView = root

    let control = PageControlView(frame: NSRect(x: 100, y: 80, width: 280, height: 32))
    control.numberOfPages = 4
    root.addSubview(control)
    root.layoutSubtreeIfNeeded()

    let buttons = control.buttonsForTesting.filter { !$0.isHidden }
    #expect(buttons.count == 6, "two chevrons and four dots should be showing")
    for button in buttons {
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hit = try #require(root.hitTest(center))
        #expect(hit === button || hit.isDescendant(of: button), "a click at \(button.accessibilityLabel() ?? "a button") landed on \(hit)")
        // The glass can only respond to the buttons it contains.
        if #available(macOS 27, *), !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let glass = sequence(first: button.superview, next: { $0?.superview })
                .compactMap { $0 as? NSGlassEffectView }
                .first
            #expect(glass?.effectIsInteractive == true, "on macOS 27 the page control's glass should contain its buttons")
        }
    }
}
