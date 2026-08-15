import AppKit
import Testing
@testable import Grid

@Test @MainActor func pageControlChevronsTrackPageBoundariesAndAccessibility() {
    let control = PageControlView(frame: .zero)
    let chevrons = control.subviews.compactMap { $0 as? NSButton }
    #expect(chevrons.count == 2)
    guard chevrons.count == 2 else { return }

    let previous = chevrons[0]
    let next = chevrons[1]
    control.numberOfPages = 3

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
