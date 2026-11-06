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

// MARK: Choosing the window

private let documentFrame = CGRect(x: 100, y: 200, width: 640, height: 480)
private let otherFrame = CGRect(x: 800, y: 300, width: 640, height: 480)

private func target(title: String = "Doc", frame: CGRect = documentFrame) -> WindowInfo {
    WindowInfo(id: 1, title: title, ownerBundleIdentifier: "com.example.app", ownerProcessID: 1, frame: frame, isOnScreen: true)
}

private func candidate(_ title: String, _ frame: CGRect) -> WindowActivator.Candidate {
    .init(title: title, origin: frame.origin, size: frame.size)
}

/// Taking whichever matched title *or* frame first closed another window of the
/// same app: one with the same title elsewhere, or one in the same spot.
@Test func aWindowWithTheSameTitleElsewhereIsNotTheOne() {
    let candidates = [candidate("Doc", otherFrame), candidate("Doc", documentFrame)]
    #expect(WindowActivator.bestMatch(for: target(), among: candidates) == 1)
}

@Test func aWindowInTheSameSpotWithAnotherTitleIsNotTheOne() {
    let candidates = [candidate("Something else", documentFrame), candidate("Doc", documentFrame)]
    #expect(WindowActivator.bestMatch(for: target(), among: candidates) == 1)
}

@Test func twoCandidatesThatFitEquallyWellAreNotGuessedBetween() {
    let identical = [candidate("Doc", documentFrame), candidate("Doc", documentFrame)]
    #expect(WindowActivator.bestMatch(for: target(), among: identical) == nil)

    let sameTitleBothMoved = [candidate("Doc", otherFrame), candidate("Doc", CGRect(x: 5, y: 5, width: 600, height: 400))]
    #expect(WindowActivator.bestMatch(for: target(), among: sameTitleBothMoved) == nil)
}

@Test func aSingleWindowSingledOutByEitherTitleOrFrameIsStillFound() {
    // Title edited since the list was made: the frame alone singles it out.
    #expect(WindowActivator.bestMatch(for: target(), among: [candidate("Doc — edited", documentFrame), candidate("Other", otherFrame)]) == 0)
    // Window moved: the title alone does.
    #expect(WindowActivator.bestMatch(for: target(), among: [candidate("Doc", otherFrame), candidate("Other", CGRect(x: 1, y: 1, width: 200, height: 200))]) == 0)
}

@Test func anEmptyTitleIdentifiesNothing() {
    let untitled = target(title: "")
    #expect(WindowActivator.bestMatch(for: untitled, among: [candidate("", otherFrame), candidate("", CGRect(x: 1, y: 1, width: 200, height: 200))]) == nil)
    #expect(WindowActivator.bestMatch(for: untitled, among: [candidate("", documentFrame), candidate("", otherFrame)]) == 0)
}

@Test func noCandidatesGivesNoMatch() {
    #expect(WindowActivator.bestMatch(for: target(), among: []) == nil)
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
