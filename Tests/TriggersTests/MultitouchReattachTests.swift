import Testing
@testable import Triggers

/// The listener registers a callback per device when it starts, so a trackpad
/// that turns up later has none until it is attached again.

@Test func aListenerThatIsNotWantedNeverAttaches() {
    #expect(!MultitouchGestureTrigger.shouldReattach(isWanted: false, attached: 0, present: 1))
    #expect(!MultitouchGestureTrigger.shouldReattach(isWanted: false, attached: 1, present: 2))
}

/// Re-attaching used to depend on already holding a device, so a listener that
/// had started with none — or lost them in a failed re-attach — never came back
/// when one appeared.
@Test func aWantedListenerHoldingNothingAttachesWhenADeviceAppears() {
    #expect(MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: 0, present: 1))
    #expect(!MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: 0, present: 0))
}

@Test func aWantedListenerAttachesAgainWhenTheCountMoves() {
    #expect(MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: 1, present: 2))
    #expect(MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: 2, present: 1))
    #expect(MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: 1, present: 0))
    #expect(!MultitouchGestureTrigger.shouldReattach(isWanted: true, attached: 1, present: 1))
}
