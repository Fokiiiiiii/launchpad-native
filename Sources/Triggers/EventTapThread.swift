import CoreFoundation
import Foundation

/// A thread of its own for the app's active event taps.
///
/// An active tap holds on to each event it watches until its callback
/// returns. The gesture tap watches every trackpad gesture on the system — the
/// ones Mission Control and Spaces use included — so while it ran on the main
/// run loop, anything that kept the main thread busy held those gestures up
/// for as long: drawing the next page at the start of a swipe took 200–330ms.
/// On this thread a callback waits only for the callbacks before it.
///
/// Sources are added and removed on the thread itself, so once `remove`
/// returns no callback of that tap is running or can start. The taps hand
/// their callbacks unretained pointers, which must never outlive what they
/// point to.
final class EventTapThread: @unchecked Sendable {
    static let shared = EventTapThread()

    private let runLoop: CFRunLoop

    private init() {
        final class Startup: @unchecked Sendable {
            var runLoop: CFRunLoop?
            let started = DispatchSemaphore(value: 0)
        }
        let startup = Startup()
        let thread = Thread {
            let runLoop = CFRunLoopGetCurrent()
            // A run loop with nothing to wait for returns at once; a timer that
            // never fires keeps it waiting between taps.
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(runLoop, keepAlive, .commonModes)
            startup.runLoop = runLoop
            startup.started.signal()
            while true {
                CFRunLoopRun()
            }
        }
        thread.name = "com.launchpadnative.event-taps"
        thread.qualityOfService = .userInteractive
        thread.start()
        startup.started.wait()
        runLoop = startup.runLoop!
    }

    /// Whether the caller is already on the tap thread.
    var isCurrent: Bool {
        CFRunLoopGetCurrent() === runLoop
    }

    /// Runs `block` on the tap thread and returns once it has run. Called from
    /// the tap thread itself, it runs `block` straight away rather than
    /// waiting on itself.
    func performAndWait(_ block: @escaping () -> Void) {
        if isCurrent {
            block()
            return
        }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            block()
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
    }

    func add(_ source: CFRunLoopSource) {
        performAndWait {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }

    /// Removes `source`. Once this returns, none of its callbacks is running.
    func remove(_ source: CFRunLoopSource) {
        performAndWait {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }
}
