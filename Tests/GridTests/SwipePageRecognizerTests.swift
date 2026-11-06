import AppKit
import Testing
@testable import Grid

/// Builds a scroll event of the shape a trackpad produces. `NSEvent`'s public
/// initializers cannot set scrolling deltas or phases, so this goes through
/// CoreGraphics — the same path the window server itself uses.
@MainActor
private func scrollEvent(dx: Double, dy: Double, phase: CGScrollPhase?, precise: Bool = true) -> NSEvent? {
    guard let cg = CGEvent(
        scrollWheelEvent2Source: nil,
        units: precise ? .pixel : .line,
        wheelCount: 2,
        wheel1: Int32(dy),
        wheel2: Int32(dx),
        wheel3: 0
    ) else { return nil }
    if precise {
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
    }
    if let phase {
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
    }
    return NSEvent(cgEvent: cg)
}

/// A scroll event carrying only a momentum phase, the way a driver that does not
/// report the scroll phase itself delivers the tail of a swipe.
@MainActor
private func momentumEvent(dx: Double, momentum: CGMomentumScrollPhase) -> NSEvent? {
    guard let cg = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(dx), wheel3: 0
    ) else { return nil }
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
    return NSEvent(cgEvent: cg)
}

/// The engage gate is the whole reason this recognizer exists: an earlier
/// version fired on the first sample that merely looked horizontal, and
/// incidental trackpad motion could trigger a full overlay takeover.
@Test @MainActor func aSwipeShorterThanTheEngageDistanceNeverBegins() throws {
    let recognizer = SwipePageRecognizer()
    var began = 0
    recognizer.callbacks.onBegan = { began += 1 }

    guard let start = scrollEvent(dx: 0, dy: 0, phase: .began),
          let jitter = scrollEvent(dx: 4, dy: 2, phase: .changed) else { return }
    recognizer.handle(start)
    recognizer.handle(jitter)
    #expect(began == 0)
}

@Test @MainActor func aRealHorizontalSwipeBeginsAndReportsItsCumulativeDelta() throws {
    let recognizer = SwipePageRecognizer()
    var began = 0
    var lastChanged: CGFloat?
    var ended: (delta: CGFloat, velocity: CGFloat)?
    recognizer.callbacks.onBegan = { began += 1 }
    recognizer.callbacks.onChanged = { lastChanged = $0 }
    recognizer.callbacks.onEnded = { ended = ($0, $1) }

    guard let start = scrollEvent(dx: 0, dy: 0, phase: .began),
          let move = scrollEvent(dx: 30, dy: 0, phase: .changed),
          let stop = scrollEvent(dx: 0, dy: 0, phase: .ended) else { return }
    recognizer.handle(start)
    recognizer.handle(move)
    recognizer.handle(move)
    recognizer.handle(stop)

    #expect(began == 1)
    // Cumulative, not per-frame: two 30pt samples report 60.
    #expect(lastChanged == 60)
    #expect(ended?.delta == 60)
}

/// Horizontal has unconditional priority when both axes clear the gate at
/// once. A version that instead picked whichever axis was momentarily larger
/// locked to vertical for the whole gesture whenever fingers landed with a
/// downward blip — a confirmed regression of the long-working horizontal swipe.
@Test @MainActor func horizontalWinsWhenBothAxesClearTheGate() throws {
    let recognizer = SwipePageRecognizer()
    var endedDelta: CGFloat?
    recognizer.callbacks.onEnded = { delta, _ in endedDelta = delta }

    guard let start = scrollEvent(dx: 0, dy: 0, phase: .began),
          // Y is larger, but X has already cleared the engage distance.
          let diagonal = scrollEvent(dx: 15, dy: 40, phase: .changed),
          let stop = scrollEvent(dx: 0, dy: 0, phase: .ended) else { return }
    recognizer.handle(start)
    recognizer.handle(diagonal)
    recognizer.handle(stop)

    // The horizontal accumulation, not the larger vertical one.
    #expect(endedDelta == 15)
}

/// Vertical still engages when it is the only axis doing anything — the grid
/// has no vertical scroll content of its own, so that axis pages too.
@Test @MainActor func aClearlyVerticalSwipeEngagesOnThatAxis() throws {
    let recognizer = SwipePageRecognizer()
    var endedDelta: CGFloat?
    recognizer.callbacks.onEnded = { delta, _ in endedDelta = delta }

    guard let start = scrollEvent(dx: 0, dy: 0, phase: .began),
          let down = scrollEvent(dx: 1, dy: 30, phase: .changed),
          let stop = scrollEvent(dx: 0, dy: 0, phase: .ended) else { return }
    recognizer.handle(start)
    recognizer.handle(down)
    recognizer.handle(stop)

    #expect(endedDelta == 30)
}

/// A driver that reports precise deltas but no phases never says the swipe is
/// over, so the page was never settled. Going quiet is taken as the end.
@Test @MainActor func aSwipeWithNoPhasesEndsWhenTheSamplesStop() throws {
    let recognizer = SwipePageRecognizer()
    var began = 0
    var ended: [CGFloat] = []
    recognizer.callbacks.onBegan = { began += 1 }
    recognizer.callbacks.onEnded = { delta, _ in ended.append(delta) }

    guard let move = scrollEvent(dx: 30, dy: 0, phase: nil) else { return }
    recognizer.handle(move)
    recognizer.handle(move)
    #expect(ended.isEmpty, "nothing has said it ended yet")

    recognizer.finishIdleGesture()
    #expect(ended == [60])

    // And the next burst is a new swipe, not suppressed by the one before.
    recognizer.handle(move)
    recognizer.handle(move)
    recognizer.finishIdleGesture()
    #expect(began == 2)
    #expect(ended == [60, 60])
}

@Test @MainActor func aQuietRecognizerEndsNothing() throws {
    let recognizer = SwipePageRecognizer()
    var ended = 0
    recognizer.callbacks.onEnded = { _, _ in ended += 1 }

    recognizer.finishIdleGesture()

    #expect(ended == 0)
}

/// A series that opens with a momentum phase is a new series. Left alone, the
/// one before it — marked complete — suppressed every later one.
@Test @MainActor func aSecondMomentumOnlySwipeIsNotSuppressed() throws {
    let recognizer = SwipePageRecognizer()
    var began = 0
    var ended: [CGFloat] = []
    recognizer.callbacks.onBegan = { began += 1 }
    recognizer.callbacks.onEnded = { delta, _ in ended.append(delta) }

    for _ in 0..<2 {
        guard let start = momentumEvent(dx: 0, momentum: .begin),
              let move = momentumEvent(dx: 30, momentum: .continuous),
              let stop = momentumEvent(dx: 0, momentum: .end) else { return }
        recognizer.handle(start)
        recognizer.handle(move)
        recognizer.handle(move)
        recognizer.handle(stop)
    }

    #expect(began == 2)
    #expect(ended == [60, 60])
}

/// A plain wheel mouse has no phases at all, and was once swallowed entirely by
/// the trackpad-only guard.
@Test @MainActor func plainWheelTicksPageDiscretely() throws {
    let recognizer = SwipePageRecognizer()
    var pages: [Int] = []
    recognizer.callbacks.onDiscretePage = { pages.append($0) }

    guard let tick = scrollEvent(dx: -3, dy: 0, phase: nil, precise: false) else { return }
    recognizer.handle(tick)
    // The cooldown exists so one physical detent cannot fire twice.
    recognizer.handle(tick)
    #expect(pages == [1])
}
