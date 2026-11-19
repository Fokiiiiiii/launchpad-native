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
///
/// Every gesture on the system passes through this tap, so it runs on
/// `EventTapThread` rather than the main run loop, where the main thread
/// being busy held every gesture up with it.
public final class GestureEventTapCoordinator {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: GestureEventTapCoordinator?
    private static let permissionPromptKey = "gestureEventTapPermissionPrompted.v1"

    struct ContactState {
        private(set) var deviceID: Int32?
        private var lastFrameTime: TimeInterval = 0
        private static let staleAfter: TimeInterval = 1

        mutating func record(deviceID: Int32, count: Int, valid: Bool, selected: Int, now: TimeInterval) {
            if now - lastFrameTime > Self.staleAfter { self.deviceID = nil }
            if self.deviceID == deviceID {
                if count == 0 { self.deviceID = nil } else { lastFrameTime = now }
            } else if self.deviceID == nil && valid && count == selected {
                self.deviceID = deviceID
                lastFrameTime = now
            }
        }

        func shouldSuppress(eventType: UInt32, eventTouchCount: Int, selected: Int, now: TimeInterval) -> Bool {
            if eventType == 29 { return eventTouchCount == selected }
            return eventType == 30 && deviceID != nil && now >= lastFrameTime && now - lastFrameTime <= Self.staleAfter
        }
    }

    private var contacts = ContactState()

    /// Guards what the callback reads on the tap thread.
    private let stateLock = NSLock()
    private var selectedFingerCount = 4
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
        selectedFingerCount = selected
        contacts = ContactState()
        stateLock.unlock()

        // NSEvent gesture events are not represented by CGEventType. The
        // public gesture mask is its documented event-bit value.
        let gestureEventTypeRawValue: CGEventType.RawValue = 29
        let magnifyEventTypeRawValue: CGEventType.RawValue = 30
        let eventMask = (CGEventMask(1) << gestureEventTypeRawValue) | (CGEventMask(1) << magnifyEventTypeRawValue)
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

        stateLock.lock()
        self.tap = tap
        stateLock.unlock()
        self.runLoopSource = source
        EventTapThread.shared.add(source)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        DiagnosticsLog.triggers.info("Gesture event tap enabled for \(selected)-finger Launchpad gestures")
        return true
    }

    public func stop() {
        stateLock.lock()
        // Thread-safe CoreFoundation objects, handed to the tap thread below.
        nonisolated(unsafe) let tap = self.tap
        self.tap = nil
        contacts = ContactState()
        stateLock.unlock()
        nonisolated(unsafe) let source = runLoopSource
        runLoopSource = nil
        if tap != nil || source != nil {
            // On the tap's own thread, so no callback is still running once
            // this returns.
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
        clearCurrent()
    }

    private func clearCurrent() {
        Self.lock.lock()
        if Self.current === self {
            Self.current = nil
        }
        Self.lock.unlock()
    }

    func recordContactFrame(deviceID: Int32, count: Int, valid: Bool) {
        stateLock.lock()
        contacts.record(deviceID: deviceID, count: count, valid: valid, selected: selectedFingerCount, now: ProcessInfo.processInfo.systemUptime)
        stateLock.unlock()
    }

    private func shouldSuppress(eventType: UInt32, eventTouchCount: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return contacts.shouldSuppress(eventType: eventType, eventTouchCount: eventTouchCount, selected: selectedFingerCount, now: ProcessInfo.processInfo.systemUptime)
    }

    private func reenableTap() {
        stateLock.lock()
        let tap = self.tap
        stateLock.unlock()
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
        case let eventType where eventType.rawValue == 29 || eventType.rawValue == 30:
            let count = eventType.rawValue == 29 ? (NSEvent(cgEvent: event)?.allTouches().count ?? 0) : 0
            return coordinator.shouldSuppress(eventType: eventType.rawValue, eventTouchCount: count)
                ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
