import Testing
@testable import Triggers

/// The launcher is this app's own window, and the global monitor never sees events
/// sent to it: without a local one the pointer leaving a corner over the open
/// launcher goes unnoticed and the corner stays disarmed.
@Test @MainActor func startWatchesThisAppsOwnWindowsAndStopLetsGo() {
    let trigger = HotCornerTrigger(onActivate: {})

    trigger.start()
    #expect(trigger.hasLocalMonitor)

    trigger.start()
    trigger.stop()
    #expect(!trigger.hasLocalMonitor)

    trigger.start()
    #expect(trigger.hasLocalMonitor, "a trigger could not be started again after it was stopped")
    trigger.stop()
}
