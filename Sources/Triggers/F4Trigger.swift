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
@MainActor
public final class F4Trigger {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onActivate: () -> Void
    public private(set) var isActive = false

    public init(onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
    }

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }

        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED; not a CGEventType enum case
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passRetained(event) }
                let trigger = Unmanaged<F4Trigger>.fromOpaque(userInfo).takeUnretainedValue()
                // The system switches a tap off if its callback ever takes too
                // long, or on certain user input. Nothing turns it back on by
                // itself: without this the key silently stops working for the
                // rest of the process's life while `isActive` still says true.
                // Same handling as the gesture tap.
                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    trigger.reenableTap()
                    DiagnosticsLog.triggers.error("F4 event tap was disabled by the system (\(type.rawValue)); re-enabled it")
                    return Unmanaged.passRetained(event)
                default:
                    return trigger.handle(event: event)
                }
            },
            userInfo: selfPointer
        ) else {
            DiagnosticsLog.triggers.error("CGEventTap creation failed (missing Input Monitoring permission for this app bundle?)")
            isActive = false
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        return true
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Matches the gesture tap: without invalidating the port, the
            // Mach port outlives the run-loop source removal.
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isActive = false
    }

    private func reenableTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passRetained(event) }
        guard let classified = F4EventClassifier.classify(subtype: Int(nsEvent.subtype.rawValue), data1: nsEvent.data1) else {
            return Unmanaged.passRetained(event)
        }
        if F4EventClassifier.isLaunchPanelActivation(classified) {
            onActivate()
            return nil // consume: suppress the system's own handling for this key
        }
        // Key-up / repeat for the Launch Panel key is still consumed so the
        // system doesn't act on the paired events of a press we intercepted.
        if classified.keyCode == F4EventClassifier.launchPanelKeyCode {
            return nil
        }
        return Unmanaged.passRetained(event)
    }

    // No deinit: same reasoning as GlobalHotkeyTrigger — callers stop() the
    // tap explicitly before releasing the last reference.
}
