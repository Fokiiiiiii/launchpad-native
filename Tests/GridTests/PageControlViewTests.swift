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
