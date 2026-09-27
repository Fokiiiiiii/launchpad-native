import CoreFoundation
import Foundation
import Testing
@testable import Triggers

/// The event taps' callbacks must not run on the main thread: the gesture tap
/// holds every trackpad gesture on the system until its callback returns.
@Test func theEventTapThreadIsNotTheMainThread() {
    final class Seen: @unchecked Sendable {
        var onMain = true
        var onTapThread = false
    }
    let seen = Seen()
    EventTapThread.shared.performAndWait {
        seen.onMain = Thread.isMainThread
        seen.onTapThread = EventTapThread.shared.isCurrent
    }
    #expect(seen.onMain == false)
    #expect(seen.onTapThread)
}

/// A source added to the tap thread is served there, and once `remove`
/// returns it is not served at all — what lets a tap hand its callback an
/// unretained pointer safely.
@Test func aSourceOnTheEventTapThreadIsServedThereUntilRemoved() throws {
    final class Probe: @unchecked Sendable {
        let fired = DispatchSemaphore(value: 0)
        var firedOnTapThread = false
    }
    let probe = Probe()
    var context = CFRunLoopSourceContext()
    context.info = Unmanaged.passUnretained(probe).toOpaque()
    context.perform = { info in
        guard let info else { return }
        let probe = Unmanaged<Probe>.fromOpaque(info).takeUnretainedValue()
        probe.firedOnTapThread = EventTapThread.shared.isCurrent
        probe.fired.signal()
    }
    let source = try #require(CFRunLoopSourceCreate(nil, 0, &context))

    EventTapThread.shared.add(source)
    CFRunLoopSourceSignal(source)
    EventTapThread.shared.performAndWait {}
    #expect(probe.fired.wait(timeout: .now() + 2) == .success)
    #expect(probe.firedOnTapThread)

    EventTapThread.shared.remove(source)
    CFRunLoopSourceSignal(source)
    EventTapThread.shared.performAndWait {}
    #expect(probe.fired.wait(timeout: .now() + 0.3) == .timedOut)
}

/// A tap stopped from inside its own callback must not wait on itself.
@Test func performAndWaitFromTheTapThreadRunsStraightAway() {
    final class Order: @unchecked Sendable { var steps: [String] = [] }
    let order = Order()
    EventTapThread.shared.performAndWait {
        order.steps.append("outer")
        EventTapThread.shared.performAndWait {
            order.steps.append("inner")
        }
        order.steps.append("after")
    }
    #expect(order.steps == ["outer", "inner", "after"])
}
