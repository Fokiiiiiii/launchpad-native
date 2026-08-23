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

    recognizer.ingest(quad(spread: 1.0)) // baseline frame 1
    recognizer.ingest(quad(spread: 1.0)) // baseline frame 2
    recognizer.ingest(quad(spread: 1.0)) // baseline frame 3
    recognizer.ingest(quad(spread: 0.5)) // below 60% of baseline -> fires pinch
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

    recognizer.ingest(quad(spread: 1.0)) // baseline frame 1
    recognizer.ingest(quad(spread: 1.0)) // baseline frame 2
    recognizer.ingest(quad(spread: 1.0)) // baseline frame 3
    recognizer.ingest(quad(spread: 1.5)) // above 140% of baseline -> fires spread
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
    recognizer.ingest(quad(spread: 1.0))
    recognizer.ingest(quad(spread: 1.0))
    recognizer.ingest(quad(spread: 1.1))

    #expect(fireCount == 0)
}

@Test func rearmsAfterAllFingersLift() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6, openingRatio: 1.4)
    var pinchCount = 0
    recognizer.onPinchDetected = { pinchCount += 1 }

    recognizer.ingest(quad(spread: 1.0))
    recognizer.ingest(quad(spread: 1.0))
    recognizer.ingest(quad(spread: 1.0))
    recognizer.ingest(quad(spread: 0.4)) // fires
    recognizer.ingest([]) // all fingers lift -> re-arm
    recognizer.ingest(quad(spread: 1.0)) // new gesture baseline frame 1
    recognizer.ingest(quad(spread: 1.0)) // baseline frame 2
    recognizer.ingest(quad(spread: 1.0)) // baseline frame 3
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
    recognizer.ingest(quintet(spread: 1.0))
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

    recognizer.ingest(quintet(spread: 1.0)) // baseline frame 1 at 5
    recognizer.ingest(quintet(spread: 1.0)) // baseline frame 2
    recognizer.ingest(quintet(spread: 1.0)) // baseline frame 3
    recognizer.ingest(quintet(spread: 0.4)) // fires under the new count
    #expect(pinchCount == 1)
}


/// The sensitivity slider is a live setting: changing the closing ratio
/// resets any in-flight gesture and the next gesture uses the new threshold.
@Test func updateClosingRatioSwitchesThresholdAtRuntime() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6, openingRatio: 1.4)
    var pinchCount = 0
    recognizer.onPinchDetected = { pinchCount += 1 }

    recognizer.ingest(quad(spread: 1.0))
    recognizer.ingest(quad(spread: 1.0))
    recognizer.ingest(quad(spread: 1.0))
    recognizer.updateClosingRatio(0.8)
    recognizer.ingest(quad(spread: 1.0)) // baseline frame 1 under new ratio
    recognizer.ingest(quad(spread: 1.0)) // baseline frame 2
    recognizer.ingest(quad(spread: 1.0)) // baseline frame 3
    recognizer.ingest(quad(spread: 0.75)) // 75% is now below the 80% threshold
    #expect(pinchCount == 1)
}

@Test func acceptsFourAndFiveContactsWithOneRecognizer() {
    let recognizer = PinchGestureRecognizer(
        closingRatio: 0.6,
        acceptedContactCounts: [4, 5]
    )
    var pinchCount = 0
    recognizer.onPinchDetected = { pinchCount += 1 }

    for _ in 0..<3 { recognizer.ingest(quad(spread: 1.0)) }
    recognizer.ingest(quad(spread: 0.4))
    recognizer.ingest([])
    for _ in 0..<3 { recognizer.ingest(quintet(spread: 1.0)) }
    recognizer.ingest(quintet(spread: 0.4))

    #expect(pinchCount == 2)
}

@Test func mismatchedCountResetsBaselineBeforeNextGesture() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6)
    var pinchCount = 0
    recognizer.onPinchDetected = { pinchCount += 1 }

    for _ in 0..<3 { recognizer.ingest(quad(spread: 1.0)) }
    recognizer.ingest(pair(spread: 0.1)) // mismatch resets the candidate
    recognizer.ingest(quad(spread: 0.4)) // first frame of a fresh baseline
    #expect(pinchCount == 0)
    for _ in 0..<2 { recognizer.ingest(quad(spread: 1.0)) }
    recognizer.ingest(quad(spread: 0.4))

    #expect(pinchCount == 1)
}

@Test func contactIDChangeResetsBaseline() {
    let recognizer = PinchGestureRecognizer(closingRatio: 0.6)
    var pinchCount = 0
    recognizer.onPinchDetected = { pinchCount += 1 }

    for _ in 0..<3 { recognizer.ingest(quad(spread: 1.0)) }
    let changedIDs = quad(spread: 0.4).enumerated().map { index, touch in
        TouchSample(id: touch.id + (index == 0 ? 100 : 0), x: touch.x, y: touch.y, size: touch.size)
    }
    recognizer.ingest(changedIDs)
    #expect(pinchCount == 0)
    for _ in 0..<2 {
        recognizer.ingest(quad(spread: 1.0).enumerated().map { index, touch in
            TouchSample(id: touch.id + (index == 0 ? 100 : 0), x: touch.x, y: touch.y, size: touch.size)
        })
    }
    recognizer.ingest(changedIDs)

    #expect(pinchCount == 1)
}

@Test func defaultOpeningRatioIsOnePointThreeFive() {
    let recognizer = PinchGestureRecognizer()
    var spreadCount = 0
    recognizer.onSpreadDetected = { spreadCount += 1 }

    for _ in 0..<3 { recognizer.ingest(quad(spread: 1.0)) }
    recognizer.ingest(quad(spread: 1.35))

    #expect(spreadCount == 1)
}

@Test func deviceRouterKeepsActiveGestureIsolatedFromOtherDevices() {
    var router = GestureDeviceRouter()

    let first = router.accepts(deviceID: 11, sampleCount: 4, hasUniqueIDs: true)
    let foreignEmpty = router.accepts(deviceID: 22, sampleCount: 0, hasUniqueIDs: true)
    let foreignInvalid = router.accepts(deviceID: 22, sampleCount: 3, hasUniqueIDs: true)
    #expect(first)
    #expect(!foreignEmpty)
    #expect(!foreignInvalid)
    #expect(router.activeDeviceID == 11)
    let continuation = router.accepts(deviceID: 11, sampleCount: 4, hasUniqueIDs: true)
    #expect(continuation)

    let end = router.accepts(deviceID: 11, sampleCount: 0, hasUniqueIDs: true)
    #expect(end)
    #expect(router.activeDeviceID == nil)
    let nextDevice = router.accepts(deviceID: 22, sampleCount: 5, hasUniqueIDs: true)
    #expect(nextDevice)
}

@Test func deviceRouterDropsInvalidFramesBeforeClaimingDevice() {
    var router = GestureDeviceRouter()

    let invalidCount = router.accepts(deviceID: 11, sampleCount: 3, hasUniqueIDs: true)
    let duplicateIDs = router.accepts(deviceID: 11, sampleCount: 4, hasUniqueIDs: false)
    #expect(!invalidCount)
    #expect(!duplicateIDs)
    #expect(router.activeDeviceID == nil)
    let valid = router.accepts(deviceID: 11, sampleCount: 4, hasUniqueIDs: true)
    #expect(valid)
}

@Test func deviceRouterReservesOnlySelectedFingerCount() {
    var router = GestureDeviceRouter(acceptedContactCounts: [5])

    let fourBeforeClaim = router.accepts(deviceID: 11, sampleCount: 4, hasUniqueIDs: true)
    let fiveClaim = router.accepts(deviceID: 11, sampleCount: 5, hasUniqueIDs: true)
    let fourDuringGesture = router.accepts(deviceID: 11, sampleCount: 4, hasUniqueIDs: true)
    let activeAfterInvalid = router.activeDeviceID
    let reclaim = router.accepts(deviceID: 11, sampleCount: 5, hasUniqueIDs: true)
    #expect(!fourBeforeClaim)
    #expect(fiveClaim)
    #expect(fourDuringGesture)
    #expect(activeAfterInvalid == nil)
    #expect(reclaim)
}

/// The multitouch framework can report a frame whose contacts share an
/// identifier — a device hiccup, or two devices' frames interleaved. Four
/// contacts that are really two fingers say nothing about how far apart four
/// fingers are, so such frames must not establish a baseline or fire off one.
///
/// The identifier *set* is compared frame to frame elsewhere, which already
/// rejects a single bad frame in the middle of a clean gesture. What only the
/// uniqueness check catches is a run of consistently duplicated frames: the
/// set matches itself every time, so the gesture would otherwise proceed
/// normally on half as many fingers as it thinks it has.
@Test func framesWithDuplicateContactIDsNeverFire() {
    func duplicated(spread: Float) -> [TouchSample] {
        [
            TouchSample(id: 1, x: 0, y: 0, size: 1),
            TouchSample(id: 1, x: 0, y: 0, size: 1),
            TouchSample(id: 2, x: spread, y: spread, size: 1),
            TouchSample(id: 2, x: spread, y: spread, size: 1)
        ]
    }

    let recognizer = PinchGestureRecognizer(closingRatio: 0.6, openingRatio: 1.4)
    var pinchCount = 0
    var spreadCount = 0
    recognizer.onPinchDetected = { pinchCount += 1 }
    recognizer.onSpreadDetected = { spreadCount += 1 }

    recognizer.ingest(duplicated(spread: 1.0))
    recognizer.ingest(duplicated(spread: 1.0))
    recognizer.ingest(duplicated(spread: 1.0))
    recognizer.ingest(duplicated(spread: 0.3))
    #expect(pinchCount == 0, "a run of duplicate-ID frames was treated as a real pinch")

    recognizer.ingest(duplicated(spread: 3.0))
    #expect(spreadCount == 0, "a run of duplicate-ID frames was treated as a real spread")
}
