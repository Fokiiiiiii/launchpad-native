import CoreGraphics
import Testing
@testable import WindowBrowser

@Test func frameMatchingAcceptsAccessibilityRoundingNoise() {
    #expect(WindowActivator.matchesFrame(
        expected: CGRect(x: 100, y: 200, width: 640, height: 480),
        origin: CGPoint(x: 101.5, y: 198.5),
        size: CGSize(width: 641.5, height: 478.5)
    ))
}

@Test func frameMatchingRejectsMissingAccessibilityAttributes() {
    let expected = CGRect(x: 100, y: 200, width: 640, height: 480)
    #expect(!WindowActivator.matchesFrame(expected: expected, origin: nil, size: CGSize(width: 640, height: 480)))
    #expect(!WindowActivator.matchesFrame(expected: expected, origin: CGPoint(x: 100, y: 200), size: nil))
}

@Test func frameMatchingRejectsAWindowOutsideTolerance() {
    #expect(!WindowActivator.matchesFrame(
        expected: CGRect(x: 100, y: 200, width: 640, height: 480),
        origin: CGPoint(x: 103, y: 200),
        size: CGSize(width: 640, height: 480)
    ))
}
