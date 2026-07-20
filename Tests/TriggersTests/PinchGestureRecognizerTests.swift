import Testing
@testable import Triggers

private func square(spread: Float) -> [TouchSample] {
    [
        TouchSample(id: 1, x: 0, y: 0, size: 1),
        TouchSample(id: 2, x: spread, y: 0, size: 1),
        TouchSample(id: 3, x: 0, y: spread, size: 1),
        TouchSample(id: 4, x: spread, y: spread, size: 1)
    ]
}

@Test func firesOnceWhenFourContactsCloseTogether() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6)
    var fireCount = 0
    recognizer.onPinchDetected = { fireCount += 1 }

    recognizer.ingest(square(spread: 1.0)) // establishes initial spread
    recognizer.ingest(square(spread: 0.9))
    recognizer.ingest(square(spread: 0.5)) // below 60% of initial -> fires
    recognizer.ingest(square(spread: 0.3)) // still closed -> must not refire

    #expect(fireCount == 1)
}

@Test func doesNotFireWhenSpreadStaysWide() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6)
    var fireCount = 0
    recognizer.onPinchDetected = { fireCount += 1 }

    recognizer.ingest(square(spread: 1.0))
    recognizer.ingest(square(spread: 0.95))
    recognizer.ingest(square(spread: 0.9))

    #expect(fireCount == 0)
}

@Test func rearmsAfterAllFingersLift() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6)
    var fireCount = 0
    recognizer.onPinchDetected = { fireCount += 1 }

    recognizer.ingest(square(spread: 1.0))
    recognizer.ingest(square(spread: 0.4)) // fires
    recognizer.ingest([]) // all fingers lift -> re-arm
    recognizer.ingest(square(spread: 1.0)) // new gesture starts
    recognizer.ingest(square(spread: 0.4)) // fires again

    #expect(fireCount == 2)
}

@Test func ignoresNonFourFingerTouchCounts() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6)
    var fireCount = 0
    recognizer.onPinchDetected = { fireCount += 1 }

    recognizer.ingest([TouchSample(id: 1, x: 0, y: 0, size: 1)]) // 1 finger, ignored
    recognizer.ingest(Array(square(spread: 1.0).prefix(3))) // 3 fingers, ignored
    #expect(fireCount == 0)
}
