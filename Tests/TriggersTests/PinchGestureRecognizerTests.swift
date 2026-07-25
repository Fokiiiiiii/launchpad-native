import Testing
@testable import Triggers

private func quad(spread: Float) -> [TouchSample] {
    [
        TouchSample(id: 1, x: 0, y: 0, size: 1),
        TouchSample(id: 2, x: spread, y: 0, size: 1),
        TouchSample(id: 3, x: 0, y: spread, size: 1),
        TouchSample(id: 4, x: spread, y: spread, size: 1)
    ]
}

private func quintet(spread: Float) -> [TouchSample] {
    [
        TouchSample(id: 1, x: 0, y: 0, size: 1),
        TouchSample(id: 2, x: spread, y: 0, size: 1),
        TouchSample(id: 3, x: 0, y: spread, size: 1),
        TouchSample(id: 4, x: spread, y: spread, size: 1),
        TouchSample(id: 5, x: spread * 2, y: 0, size: 1)
    ]
}

private func pair(spread: Float) -> [TouchSample] {
    [
        TouchSample(id: 1, x: 0, y: 0, size: 1),
        TouchSample(id: 2, x: spread, y: 0, size: 1)
    ]
}

@Test func firesPinchOnceWhenFourContactsCloseTogether() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6, openingRatio: 1.4)
    var pinchCount = 0
    var spreadCount = 0
    recognizer.onPinchDetected = { pinchCount += 1 }
    recognizer.onSpreadDetected = { spreadCount += 1 }

    recognizer.ingest(quad(spread: 1.0)) // establishes initial spread
    recognizer.ingest(quad(spread: 0.9))
    recognizer.ingest(quad(spread: 0.5)) // below 60% of initial -> fires pinch
    recognizer.ingest(quad(spread: 0.3)) // still closed -> must not refire

    #expect(pinchCount == 1)
    #expect(spreadCount == 0)
}

@Test func firesSpreadOnceWhenFourContactsMoveApart() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6, openingRatio: 1.4)
    var pinchCount = 0
    var spreadCount = 0
    recognizer.onPinchDetected = { pinchCount += 1 }
    recognizer.onSpreadDetected = { spreadCount += 1 }

    recognizer.ingest(quad(spread: 1.0)) // establishes initial spread
    recognizer.ingest(quad(spread: 1.2))
    recognizer.ingest(quad(spread: 1.5)) // above 140% of initial -> fires spread
    recognizer.ingest(quad(spread: 1.8)) // still spread -> must not refire

    #expect(spreadCount == 1)
    #expect(pinchCount == 0)
}

@Test func doesNotFireWhenSpreadStaysNearStart() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6, openingRatio: 1.4)
    var fireCount = 0
    recognizer.onPinchDetected = { fireCount += 1 }
    recognizer.onSpreadDetected = { fireCount += 1 }

    recognizer.ingest(quad(spread: 1.0))
    recognizer.ingest(quad(spread: 0.95))
    recognizer.ingest(quad(spread: 1.1))

    #expect(fireCount == 0)
}

@Test func rearmsAfterAllFingersLift() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6, openingRatio: 1.4)
    var pinchCount = 0
    recognizer.onPinchDetected = { pinchCount += 1 }

    recognizer.ingest(quad(spread: 1.0))
    recognizer.ingest(quad(spread: 0.4)) // fires
    recognizer.ingest([]) // all fingers lift -> re-arm
    recognizer.ingest(quad(spread: 1.0)) // new gesture starts
    recognizer.ingest(quad(spread: 0.4)) // fires again

    #expect(pinchCount == 2)
}

@Test func ignoresNonMatchingTouchCounts() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6, openingRatio: 1.4)
    var fireCount = 0
    recognizer.onPinchDetected = { fireCount += 1 }

    recognizer.ingest([TouchSample(id: 1, x: 0, y: 0, size: 1)]) // 1 finger, ignored
    recognizer.ingest(pair(spread: 1.0)) // 2 fingers, ignored by the default 4-contact recognizer
    #expect(fireCount == 0)
}

/// Contact count is configurable (not hardcoded) — a 2-finger variant was
/// tried and rejected (collides with system pinch-to-zoom), and the default
/// itself has moved between 4 and 3 over this project's history before
/// settling on a user-selectable 4/5-finger picker (3 dropped as an option),
/// but the parameter itself stays testable/available regardless of default.
@Test func requiredContactCountIsConfigurable() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6, openingRatio: 1.4, requiredContactCount: 5)
    var pinchCount = 0
    recognizer.onPinchDetected = { pinchCount += 1 }

    recognizer.ingest(quad(spread: 1.0)) // 4 fingers, ignored when 5 are required
    recognizer.ingest(quintet(spread: 1.0))
    recognizer.ingest(quintet(spread: 0.4))

    #expect(pinchCount == 1)
}

/// Settings' 4/5-finger picker calls this at runtime rather than
/// recreating the recognizer — verifies the switch actually takes effect
/// and that a gesture mid-track under the old count doesn't carry over.
@Test func updateRequiredContactCountSwitchesRecognitionAtRuntime() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6, openingRatio: 1.4, requiredContactCount: 4)
    var pinchCount = 0
    recognizer.onPinchDetected = { pinchCount += 1 }

    recognizer.ingest(quad(spread: 1.0)) // tracking under the 4-count default
    recognizer.updateRequiredContactCount(5)
    recognizer.ingest(quad(spread: 0.4)) // still 4 contacts -> now ignored
    #expect(pinchCount == 0)

    recognizer.ingest(quintet(spread: 1.0)) // establishes initial spread at 5
    recognizer.ingest(quintet(spread: 0.4)) // fires under the new count
    #expect(pinchCount == 1)
}
