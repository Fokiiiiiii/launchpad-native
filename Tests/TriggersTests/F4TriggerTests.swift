import AppKit
import Testing
@testable import Triggers

/// A system-defined event the way the tap receives one.
@MainActor
private func systemDefinedEvent(subtype: Int16, data1: Int) throws -> CGEvent {
    let event = try #require(NSEvent.otherEvent(
        with: .systemDefined,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: subtype,
        data1: data1,
        data2: -1
    ))
    return try #require(event.cgEvent)
}

/// Volume up (key type 0) pressed.
@MainActor private func volumeUp() throws -> CGEvent {
    try systemDefinedEvent(subtype: 8, data1: (0 << 16) | (1 << 8))
}

/// A mouse-button event (subtype 7), which the classifier does not recognise.
@MainActor private func mouseButtons() throws -> CGEvent {
    try systemDefinedEvent(subtype: 7, data1: 1)
}

@MainActor private func launchPanelKey(down: Bool) throws -> CGEvent {
    try systemDefinedEvent(subtype: 8, data1: (13 << 16) | ((down ? 1 : 0) << 8))
}

/// Every system-defined event goes through the tap while F4 is on — media
/// keys, and on some mice every button press. One that is let through goes
/// back as the same event without an extra retain; returning it retained
/// kept each of them alive for the rest of the process.
@Test @MainActor func theF4TapLetsOtherSystemEventsThroughWithoutKeepingThem() throws {
    let context = F4TapContext(onActivate: {})
    for event in [try volumeUp(), try mouseButtons()] {
        let before = CFGetRetainCount(event)
        let passed = autoreleasepool { context.respond(to: event) }
        let returned = try #require(passed, "the event should have been let through")
        #expect(returned.takeUnretainedValue() === event)
        #expect(CFGetRetainCount(event) == before, "the tap kept a reference to an event it let through")
    }
}

/// The Launch Panel key itself is swallowed, pressed or released; only a
/// fresh press opens the launcher.
@Test @MainActor func theF4TapSwallowsTheLaunchPanelKey() throws {
    #expect(F4Trigger.response(to: try launchPanelKey(down: true)) == .swallowAndActivate)
    #expect(F4Trigger.response(to: try launchPanelKey(down: false)) == .swallow)
    #expect(F4Trigger.response(to: try volumeUp()) == .letThrough)
    #expect(F4Trigger.response(to: try mouseButtons()) == .letThrough)
}

/// The tap's callback runs on the tap thread; opening the launcher has to
/// happen on the main thread all the same.
@Test @MainActor func theF4TapOpensTheLauncherOnTheMainThread() async throws {
    var activations = 0
    var activatedOnMain = false
    let trigger = F4Trigger(onActivate: {
        activations += 1
        activatedOnMain = Thread.isMainThread
    })
    nonisolated(unsafe) let press = try launchPanelKey(down: true)
    let context = trigger.tapContext

    EventTapThread.shared.performAndWait {
        _ = context.respond(to: press)
    }
    for _ in 0..<50 where activations == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(activations == 1)
    #expect(activatedOnMain)
}

/// The tap's own callback, called the way the system calls it: on the tap
/// thread, with the trigger's context as `userInfo`. Written as a closure
/// inside the main-actor trigger it was main-actor-isolated, and the first
/// event on the tap thread trapped the app. The callback is read here, on the
/// main actor, so that a main-actor-isolated one would get this far and trap
/// below rather than fail to compile.
@Test @MainActor func theF4TapCallbackRunsOnTheTapThread() async throws {
    var activations = 0
    let trigger = F4Trigger(onActivate: { activations += 1 })
    let callback = F4Trigger.tapCallback
    nonisolated(unsafe) let userInfo = Unmanaged.passUnretained(trigger.tapContext).toOpaque()
    nonisolated(unsafe) let volume = try volumeUp()
    nonisolated(unsafe) let press = try launchPanelKey(down: true)
    final class Outcome: @unchecked Sendable {
        var volumeLetThrough = false
        var pressSwallowed = false
    }
    let outcome = Outcome()

    EventTapThread.shared.performAndWait {
        let proxy = OpaquePointer(bitPattern: 1)!
        let passed = callback(proxy, volume.type, volume, userInfo)
        outcome.volumeLetThrough = passed?.takeUnretainedValue() === volume
        outcome.pressSwallowed = callback(proxy, press.type, press, userInfo) == nil
    }
    for _ in 0..<50 where activations == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(outcome.volumeLetThrough)
    #expect(outcome.pressSwallowed)
    #expect(activations == 1)
}
