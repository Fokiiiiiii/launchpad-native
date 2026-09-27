import AppKit
import Diagnostics

/// Captures the F4/Launch Panel/Spotlight key globally via `CGEventTap` at
/// `.cghidEventTap` (verified installable from this machine in Phase 1 —
/// `ReverseEngineering/Contracts/f4-hid.md`) and toggles the launcher.
///
/// When enabled, the tap uses `.defaultTap` (not `.listenOnly`) so the key
/// event is *consumed* — the system's own Spotlight/Launchpad handling for
/// this key is suppressed while this trigger is active, per spec ("有効時は
/// 元のシステム動作を抑止"). When disabled, the tap isn't installed at all,
/// so the event passes through completely unmodified ("無効時はeventを変更
/// せず通過").
/// The tap runs on `EventTapThread`: it sits in front of every system-defined
/// event — media keys, and on some mice every button press — which on the
/// main run loop waited for the main thread whenever it was busy. Opening the
/// launcher is the only part that needs the main thread, and is sent there.
@MainActor
public final class F4Trigger {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onActivate: () -> Void
    public private(set) var isActive = false

    /// What the callback reaches on the tap thread.
    private(set) lazy var tapContext = F4TapContext { [weak self] in
        Task { @MainActor [weak self] in
            self?.onActivate()
        }
    }

    public init(onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
    }

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }

        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED; not a CGEventType enum case
        let context = tapContext

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: F4Trigger.tapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            DiagnosticsLog.triggers.error("CGEventTap creation failed (missing Input Monitoring permission for this app bundle?)")
            isActive = false
            return false
        }

        self.tap = tap
        context.setTap(tap)
        runLoopSource = source
        EventTapThread.shared.add(source)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        return true
    }

    /// The tap's callback, run on `EventTapThread`.
    ///
    /// A `nonisolated static` on purpose. Written as a closure inside this
    /// main-actor class's methods, it was main-actor-isolated, and Swift 6
    /// checks that at the entry of a function it hands to C: the first event
    /// to reach the tap on its own thread trapped the app.
    nonisolated static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let context = Unmanaged<F4TapContext>.fromOpaque(userInfo).takeUnretainedValue()
        // The system switches a tap off if its callback ever takes too
        // long, or on certain user input. Nothing turns it back on by
        // itself: without this the key silently stops working for the
        // rest of the process's life while `isActive` still says true.
        // Same handling as the gesture tap.
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            context.reenableTap()
            DiagnosticsLog.triggers.error("F4 event tap was disabled by the system (\(type.rawValue)); re-enabled it")
            return Unmanaged.passUnretained(event)
        default:
            return context.respond(to: event)
        }
    }

    public func stop() {
        // Thread-safe CoreFoundation objects, handed to the tap thread below.
        nonisolated(unsafe) let tap = self.tap
        nonisolated(unsafe) let source = runLoopSource
        self.tap = nil
        runLoopSource = nil
        tapContext.setTap(nil)
        if tap != nil || source != nil {
            // On the tap's own thread, so no callback is still running once
            // this returns. Invalidating matches the gesture tap: without it,
            // the Mach port outlives the run-loop source removal.
            EventTapThread.shared.performAndWait {
                if let source {
                    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                }
                if let tap {
                    CGEvent.tapEnable(tap: tap, enable: false)
                    CFMachPortInvalidate(tap)
                }
            }
        }
        isActive = false
    }

    enum TapResponse: Equatable {
        case letThrough
        case swallow
        case swallowAndActivate
    }

    /// What to do with one system-defined event.
    nonisolated static func response(to event: CGEvent) -> TapResponse {
        guard let nsEvent = NSEvent(cgEvent: event),
              let classified = F4EventClassifier.classify(subtype: Int(nsEvent.subtype.rawValue), data1: nsEvent.data1) else {
            return .letThrough
        }
        if F4EventClassifier.isLaunchPanelActivation(classified) {
            return .swallowAndActivate // suppress the system's own handling for this key
        }
        // Key-up / repeat for the Launch Panel key is still consumed so the
        // system doesn't act on the paired events of a press we intercepted.
        if classified.keyCode == F4EventClassifier.launchPanelKeyCode {
            return .swallow
        }
        return .letThrough
    }

    // No deinit: same reasoning as GlobalHotkeyTrigger — callers stop() the
    // tap explicitly before releasing the last reference.
}

/// The part of the F4 trigger its tap callback uses, from the tap thread.
final class F4TapContext: @unchecked Sendable {
    private let lock = NSLock()
    private var tap: CFMachPort?
    private let onActivate: @Sendable () -> Void

    init(onActivate: @escaping @Sendable () -> Void) {
        self.onActivate = onActivate
    }

    func setTap(_ tap: CFMachPort?) {
        lock.lock()
        self.tap = tap
        lock.unlock()
    }

    func reenableTap() {
        lock.lock()
        let tap = self.tap
        lock.unlock()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Returns the event to let it through, or nil to swallow it. An event
    /// let through goes back unretained: the tap does not own it, and
    /// returning it retained (as this used to) kept every system-defined
    /// event that passed — media keys, and on some mice every button press —
    /// alive for the rest of the process.
    func respond(to event: CGEvent) -> Unmanaged<CGEvent>? {
        switch F4Trigger.response(to: event) {
        case .letThrough:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .swallowAndActivate:
            onActivate()
            return nil
        }
    }
}
