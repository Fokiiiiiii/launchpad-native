import ApplicationServices
import AppKit
import CoreGraphics
import Diagnostics
import Foundation

/// Filters the selected Launchpad gesture at the system event boundary.
///
/// MultitouchSupport remains the passive source used by the recognizer.  The
/// event tap is the small, native arbitration layer: it removes the selected
/// 4- or 5-finger Launchpad gesture from the system stream.
public final class GestureEventTapCoordinator {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: GestureEventTapCoordinator?
    private static let permissionPromptKey = "gestureEventTapPermissionPrompted.v1"

    private let stateLock = NSLock()
    private var selectedFingerCounts: Set<Int> = [4, 5]
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public private(set) var isActive = false

    public init() {}

    @discardableResult
    public func start(fingerCount: Int) -> Bool {
        let selected = fingerCount == 5 ? 5 : 4
        stop()

        let accessibilityTrusted = AXIsProcessTrusted()
        let inputMonitoringTrusted = CGPreflightListenEventAccess()
        guard accessibilityTrusted && inputMonitoringTrusted else {
            // Permission prompts are intentionally one-shot. Re-applying
            // settings must not nag the user; the existing privacy-settings
            // button remains the explicit retry path after a grant/deny.
            if Self.shouldPromptForPermissions() {
                if !accessibilityTrusted {
                    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                }
                if !inputMonitoringTrusted {
                    _ = CGRequestListenEventAccess()
                }
            }
            DiagnosticsLog.triggers.error("Gesture event tap unavailable: Accessibility/Input Monitoring permission is not granted")
            return false
        }

        stateLock.lock()
        selectedFingerCounts = [selected]
        stateLock.unlock()

        // NSEvent gesture events are not represented by CGEventType. The
        // public gesture mask is its documented event-bit value.
        let gestureEventTypeRawValue: CGEventType.RawValue = 29
        let eventMask = CGEventMask(1) << gestureEventTypeRawValue
        Self.lock.lock()
        Self.current = self
        Self.lock.unlock()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: GestureEventTapCoordinator.eventTapCallback,
            userInfo: nil
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            clearCurrent()
            DiagnosticsLog.triggers.error("Gesture event tap could not be created")
            return false
        }

        self.tap = tap
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        DiagnosticsLog.triggers.info("Gesture event tap enabled for \(selected)-finger Launchpad gestures")
        return true
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
        isActive = false
        clearCurrent()
    }

    private func clearCurrent() {
        Self.lock.lock()
        if Self.current === self {
            Self.current = nil
        }
        Self.lock.unlock()
    }

    private func selectedFingerCountsSnapshot() -> Set<Int> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return selectedFingerCounts
    }

    private func reenableTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private static func shouldPromptForPermissions() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: permissionPromptKey) else { return false }
        defaults.set(true, forKey: permissionPromptKey)
        return true
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, _ in
        GestureEventTapCoordinator.lock.lock()
        let coordinator = GestureEventTapCoordinator.current
        GestureEventTapCoordinator.lock.unlock()
        guard let coordinator else { return Unmanaged.passUnretained(event) }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            coordinator.reenableTap()
            DiagnosticsLog.triggers.error("Gesture event tap was disabled by the system; re-enabled it")
            return Unmanaged.passUnretained(event)
        case let eventType where eventType.rawValue == 29:
            guard let nsEvent = NSEvent(cgEvent: event) else {
                return Unmanaged.passUnretained(event)
            }
            let fingerCount = nsEvent.allTouches().count
            return coordinator.selectedFingerCountsSnapshot().contains(fingerCount)
                ? nil
                : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
