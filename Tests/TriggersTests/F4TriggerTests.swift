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

/// Every system-defined event goes through the tap while F4 is on — media
/// keys, and on some mice every button press. One that is let through goes
/// back as the same event without an extra retain; returning it retained
/// kept each of them alive for the rest of the process.
@Test @MainActor func theF4TapLetsOtherSystemEventsThroughWithoutKeepingThem() throws {
    let trigger = F4Trigger(onActivate: {})
    // Volume up (key type 0) pressed, then a mouse-button event (subtype 7),
    // which the classifier does not recognise at all.
    let events = [
        try systemDefinedEvent(subtype: 8, data1: (0 << 16) | (1 << 8)),
        try systemDefinedEvent(subtype: 7, data1: 1),
    ]
    for event in events {
        let before = CFGetRetainCount(event)
        let passed = autoreleasepool { trigger.handle(event: event) }
        let returned = try #require(passed, "the event should have been let through")
        #expect(returned.takeUnretainedValue() === event)
        #expect(CFGetRetainCount(event) == before, "the tap kept a reference to an event it let through")
    }
}

/// The Launch Panel key itself is swallowed, and a fresh press opens the launcher.
@Test @MainActor func theF4TapSwallowsTheLaunchPanelKey() throws {
    var activations = 0
    let trigger = F4Trigger(onActivate: { activations += 1 })

    let press = try systemDefinedEvent(subtype: 8, data1: (13 << 16) | (1 << 8))
    #expect(trigger.handle(event: press) == nil)
    #expect(activations == 1)

    let release = try systemDefinedEvent(subtype: 8, data1: 13 << 16)
    #expect(trigger.handle(event: release) == nil)
    #expect(activations == 1)
}
