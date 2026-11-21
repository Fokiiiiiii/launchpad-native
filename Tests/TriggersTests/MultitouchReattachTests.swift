import Foundation
import Testing
@testable import Triggers

/// The listener registers a callback per device when it starts, so a trackpad
/// that turns up later has none until it is attached again.

@Test func aListenerThatIsNotWantedNeverAttaches() {
    #expect(!MultitouchGestureTrigger.shouldReattach(isWanted: false, attached: [], present: [1]))
    #expect(!MultitouchGestureTrigger.shouldReattach(isWanted: false, attached: [1], present: [1, 2]))
}

/// Re-attaching used to depend on already holding a device, so a listener that
/// had started with none — or lost them in a failed re-attach — never came back
/// when one appeared.
@Test func aWantedListenerHoldingNothingAttachesWhenADeviceAppears() {
    #expect(MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: [], present: [1]))
    #expect(!MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: [], present: []))
}

@Test func aWantedListenerAttachesAgainWhenTheSetMoves() {
    #expect(MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: [1], present: [1, 2]))
    #expect(MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: [1, 2], present: [1]))
    #expect(MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: [1], present: []))
    #expect(!MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: [1], present: [1]))
}

/// One trackpad unplugged and another plugged in leaves the count where it was.
/// Counting could not see that, and the new trackpad had no callback on it.
@Test func aSwapThatKeepsTheCountIsStillAChange() {
    #expect(MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: [1], present: [2]))
    #expect(MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: [1, 2], present: [1, 3]))
    #expect(!MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: [1, 2], present: [2, 1]))
}

/// The framework calls this on its own thread. It is read here, on the main
/// actor, and called from another thread, the way the framework does. This checked
/// a suspected trap on the first touch and did not find one, so it stays as a
/// check that the callback can be called that way.
@Test @MainActor func theFrameCallbackRunsOnAThreadOfTheFrameworksOwn() async {
    let callback = MultitouchGestureTrigger.frameCallback
    let finished = await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            // No finger and no listener started: the call has nothing to do, which
            // is all this needs, since only entering it can trap.
            continuation.resume(returning: callback(0, nil, 0, 0, 0))
        }
    }
    #expect(finished == 0)
}
