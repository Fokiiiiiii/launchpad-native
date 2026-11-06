import Testing
@testable import Triggers

/// The launcher is this app's own window, and the global monitor never sees events
/// sent to it: without a local one the pointer leaving a corner over the open
/// launcher goes unnoticed and the corner stays disarmed.
///
/// Only the local monitor is installed here. The global one needs the Input
/// Monitoring permission, and asking for it from a test machine is not something a
/// test should do.
@Test @MainActor func theLocalMonitorIsInstalledOnceAndStopLetsGo() {
    let trigger = HotCornerTrigger(onActivate: {})

    trigger.installLocalMonitor()
    trigger.installLocalMonitor()
    #expect(trigger.hasLocalMonitor)

    trigger.stop()
    #expect(!trigger.hasLocalMonitor)

    trigger.installLocalMonitor()
    #expect(trigger.hasLocalMonitor, "a trigger could not be watched again after it was stopped")
    trigger.stop()
}
