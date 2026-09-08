import Diagnostics
import Foundation

// Verified against ReverseEngineering/Contracts/multitouch.md by live
// capture on this machine — not a guessed layout.
struct MTPoint { var x: Float; var y: Float }
struct MTReadout { var position: MTPoint; var velocity: MTPoint }
struct Finger {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var foo3: Int32
    var foo4: Int32
    var normalized: MTReadout
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var mm: MTReadout
    var zero2a: Int32
    var zero2b: Int32
    var unknown2: Float
}

typealias MTContactCallbackFunction = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

public struct MultitouchActivationReport: Sendable, Equatable {
    public let rawListenerActive: Bool
    public let eventArbitrationActive: Bool

    public init(rawListenerActive: Bool, eventArbitrationActive: Bool) {
        self.rawListenerActive = rawListenerActive
        self.eventArbitrationActive = eventArbitrationActive
    }
}

/// Keeps frames from multiple registered devices from corrupting one shared
/// recognizer. MultitouchSupport can call the callback for every attached
/// device; only one device may own a gesture at a time.
struct GestureDeviceRouter {
    private(set) var activeDeviceID: Int32?
    private var acceptedContactCounts: Set<Int>

    init(acceptedContactCounts: Set<Int> = [4, 5]) {
        self.acceptedContactCounts = acceptedContactCounts
    }

    mutating func updateAcceptedContactCounts(_ counts: Set<Int>) {
        acceptedContactCounts = counts
        activeDeviceID = nil
    }

    mutating func accepts(deviceID: Int32, sampleCount: Int, hasUniqueIDs: Bool) -> Bool {
        let isValidGestureFrame = acceptedContactCounts.contains(sampleCount) && hasUniqueIDs
        guard sampleCount > 0 else {
            guard activeDeviceID == deviceID else { return false }
            activeDeviceID = nil
            return true
        }

        if let activeDeviceID {
            guard activeDeviceID == deviceID else { return false }
            if !isValidGestureFrame {
                self.activeDeviceID = nil
            }
            return true
        }

        guard isValidGestureFrame else { return false }
        activeDeviceID = deviceID
        return true
    }

    mutating func reset() {
        activeDeviceID = nil
    }
}

/// Raw multitouch Launchpad gesture trigger — pinch closed to open, spread
/// open to close. Build-gated: if the private framework or its symbols
/// aren't present, `start()` returns `false` and every other trigger keeps
/// working (capability-level fail isolation).
///
/// Performance note: `MTRegisterContactFrameCallback` fires for *any*
/// trackpad contact — cursor movement, scrolling, anything — not just the
/// gesture shape being matched, at typical multitouch frame rates
/// (60-120Hz). An earlier version hopped to the main actor with a fresh
/// `Task` on every single frame, which meant constant Task/actor-hop churn
/// system-wide any time the trackpad was touched at all — the almost
/// certain cause of a real "the whole app feels very slow" report during
/// hands-on testing. The fix: run the recognizer synchronously on the
/// callback's own (background, framework-owned) thread behind a lock, and
/// only hop to the main actor once, when a pinch is actually detected.
@MainActor
public final class MultitouchGestureTrigger {
    private var deviceHandles: [UnsafeMutableRawPointer] = []
    // MTDeviceCreateList owns the device objects through the returned array.
    // Keep that array alive for as long as the raw handles are in use; releasing
    // it at the end of start() leaves dangling pointers that crash inside
    // MTDeviceStop during application termination.
    private var deviceList: CFArray?
    private var frameworkHandle: UnsafeMutableRawPointer?
    /// Pinch (fingers closing) — real Launchpad semantics: opens.
    private let onPinchClose: () -> Void
    /// Spread (fingers opening) — real Launchpad semantics: closes.
    private let onSpreadOpen: () -> Void
    private let gestureEventTap = GestureEventTapCoordinator()
    private var selectedFingerCount: Int
    public private(set) var isActive = false
    public private(set) var isEventArbitrationActive = false

    /// Not actor-isolated on purpose: `handleFrame` runs on whatever thread
    /// MultitouchSupport calls back on (not the main thread), and the
    /// framework may call back for multiple registered devices concurrently
    /// — `lock` protects `recognizer`'s mutable state across those calls.
    nonisolated(unsafe) private let recognizer: PinchGestureRecognizer
    private let lock = NSLock()
    nonisolated(unsafe) private var deviceRouter = GestureDeviceRouter()

    /// The C callback has no context/refcon parameter to carry `self`
    /// through, so exactly one live trigger routes through this static
    /// reference — acceptable since the app only ever runs one.
    nonisolated(unsafe) private static var current: MultitouchGestureTrigger?

    /// The scalar setting selects one Launchpad-compatible contact count. The
    /// persisted scalar is kept for backwards compatibility with older layout
    /// documents and is applied to both the recognizer and event arbitration.
    public init(
        onPinchClose: @escaping () -> Void,
        onSpreadOpen: @escaping () -> Void,
        sensitivity: Float = 0.6,
        requiredContactCount: Int = 4
    ) {
        self.onPinchClose = onPinchClose
        self.onSpreadOpen = onSpreadOpen
        let selected = requiredContactCount == 5 ? 5 : 4
        self.selectedFingerCount = selected
        self.recognizer = PinchGestureRecognizer(
            closingRatio: sensitivity,
            requiredContactCount: requiredContactCount,
            acceptedContactCounts: [selected]
        )
        self.deviceRouter = GestureDeviceRouter(acceptedContactCounts: [selected])
    }

    /// Re-applies the selected count without replacing the callback
    /// registration. `recognizer` and the device router share the same lock.
    public func updateRequiredContactCount(_ count: Int) {
        let selected = count == 5 ? 5 : 4
        lock.lock()
        selectedFingerCount = selected
        deviceRouter.updateAcceptedContactCounts([selected])
        recognizer.updateAcceptedContactCounts([selected])
        lock.unlock()
    }

    /// Updates the pinch threshold while keeping the existing callback
    /// registration. Settings changes are applied under the same lock as
    /// incoming multitouch frames.
    public func updateSensitivity(_ sensitivity: Float) {
        lock.lock()
        recognizer.updateClosingRatio(sensitivity)
        lock.unlock()
    }

    @discardableResult
    public func start() -> MultitouchActivationReport {
        guard deviceHandles.isEmpty else {
            return MultitouchActivationReport(
                rawListenerActive: isActive,
                eventArbitrationActive: isEventArbitrationActive
            )
        }
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            DiagnosticsLog.triggers.error("MultitouchSupport dlopen failed; gesture trigger unavailable")
            return MultitouchActivationReport(rawListenerActive: false, eventArbitrationActive: false)
        }
        frameworkHandle = handle

        typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
        typealias MTRegisterFn = @convention(c) (UnsafeMutableRawPointer, MTContactCallbackFunction) -> Int32
        typealias MTUnregisterFn = @convention(c) (UnsafeMutableRawPointer, MTContactCallbackFunction) -> Int32
        typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32

        guard let createListSym = dlsym(handle, "MTDeviceCreateList"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let unregisterSym = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let stopSym = dlsym(handle, "MTDeviceStop") else {
            DiagnosticsLog.triggers.error("MultitouchSupport symbols missing; gesture trigger unavailable")
            return MultitouchActivationReport(rawListenerActive: false, eventArbitrationActive: false)
        }
        let createList = unsafeBitCast(createListSym, to: MTDeviceCreateListFn.self)
        let register = unsafeBitCast(registerSym, to: MTRegisterFn.self)
        let unregister = unsafeBitCast(unregisterSym, to: MTUnregisterFn.self)
        let startDevice = unsafeBitCast(startSym, to: MTDeviceStartFn.self)
        let stopDevice = unsafeBitCast(stopSym, to: (@convention(c) (UnsafeMutableRawPointer) -> Int32).self)

        guard let list = createList()?.takeRetainedValue() else {
            DiagnosticsLog.triggers.error("No multitouch devices found")
            return MultitouchActivationReport(rawListenerActive: false, eventArbitrationActive: false)
        }
        deviceList = list

        Self.current = self
        recognizer.onPinchDetected = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onPinchClose() }
        }
        recognizer.onSpreadDetected = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onSpreadOpen() }
        }

        var registeredDevices: [UnsafeMutableRawPointer] = []
        var startedDevices: [UnsafeMutableRawPointer] = []
        var failed = false
        let count = CFArrayGetCount(list)
        for i in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: ptr)
            let registerResult = register(device, MultitouchGestureTrigger.frameCallback)
            // MTRegisterContactFrameCallback returns a BOOL-like status:
            // non-zero means the callback was registered.  MTDeviceStart,
            // unlike registration, uses the conventional zero-success
            // status.  Treating registration like Start made every device
            // look failed on this machine (the live call returns 1), so the
            // listener was always torn down before it could receive frames.
            guard registerResult != 0 else {
                DiagnosticsLog.triggers.error("Multitouch contact callback registration failed (status=\(registerResult, privacy: .public))")
                failed = true
                break
            }
            registeredDevices.append(device)
            let startResult = startDevice(device, 0)
            guard startResult == 0 else {
                DiagnosticsLog.triggers.error("Multitouch device start failed (status=\(startResult, privacy: .public))")
                failed = true
                break
            }
            startedDevices.append(device)
        }
        guard !failed, !startedDevices.isEmpty else {
            for device in startedDevices {
                _ = stopDevice(device)
            }
            for device in registeredDevices {
                _ = unregister(device, MultitouchGestureTrigger.frameCallback)
            }
            deviceHandles.removeAll()
            deviceList = nil
            if Self.current === self { Self.current = nil }
            isActive = false
            isEventArbitrationActive = false
            return MultitouchActivationReport(rawListenerActive: false, eventArbitrationActive: false)
        }
        deviceHandles = startedDevices
        isActive = !deviceHandles.isEmpty
        isEventArbitrationActive = gestureEventTap.start(fingerCount: selectedFingerCount)
        if !isEventArbitrationActive {
            // Keep the raw listener alive as a fallback. The coordinator has
            // already applied the selected CFPreferences suppression, so the
            // gesture can still work on hosts where the active tap permission
            // is pending; changing the setting retries the tap.
            DiagnosticsLog.triggers.error("Multitouch listener running without the event arbitration tap")
        }
        return MultitouchActivationReport(
            rawListenerActive: isActive,
            eventArbitrationActive: isEventArbitrationActive
        )
    }

    /// Re-attaches when the set of multitouch devices no longer matches the
    /// one `start()` saw.
    ///
    /// The list is read exactly once, at start, and a callback is registered
    /// per device. A trackpad that arrives afterwards — paired over Bluetooth,
    /// or recreated by the system across a sleep/wake cycle — has no callback
    /// on it, so gestures made on it do nothing while Settings still reports
    /// the trigger as on. Calling `start()` again does not help by itself: it
    /// returns early while any handles are still held.
    ///
    /// Counting is the whole test. Comparing the handles themselves would be
    /// stricter, but the pointers come from the private framework's own array
    /// and a swap that keeps the count identical is not something this can
    /// distinguish; a device appearing or disappearing always changes it.
    @discardableResult
    public func restartIfDeviceSetChanged() -> Bool {
        guard !deviceHandles.isEmpty else { return false }
        guard let count = currentDeviceCount(), count != deviceHandles.count else { return false }
        DiagnosticsLog.triggers.info(
            "Multitouch devices changed (\(self.deviceHandles.count, privacy: .public) -> \(count, privacy: .public)); re-attaching the listener"
        )
        stop()
        start()
        return true
    }

    private func currentDeviceCount() -> Int? {
        typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
        guard let handle = frameworkHandle ?? dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createListSym = dlsym(handle, "MTDeviceCreateList") else { return nil }
        let createList = unsafeBitCast(createListSym, to: MTDeviceCreateListFn.self)
        guard let list = createList()?.takeRetainedValue() else { return 0 }
        return CFArrayGetCount(list)
    }

    public func stop() {
        gestureEventTap.stop()
        typealias MTDeviceStopFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
        typealias MTUnregisterFn = @convention(c) (UnsafeMutableRawPointer, MTContactCallbackFunction) -> Int32
        if let handle = frameworkHandle, let stopSym = dlsym(handle, "MTDeviceStop") {
            let stopDevice = unsafeBitCast(stopSym, to: MTDeviceStopFn.self)
            for device in deviceHandles { _ = stopDevice(device) }
        }
        if let handle = frameworkHandle, let unregisterSym = dlsym(handle, "MTUnregisterContactFrameCallback") {
            let unregister = unsafeBitCast(unregisterSym, to: MTUnregisterFn.self)
            for device in deviceHandles {
                _ = unregister(device, MultitouchGestureTrigger.frameCallback)
            }
        }
        deviceHandles.removeAll()
        deviceList = nil
        lock.lock()
        deviceRouter.reset()
        recognizer.ingest([])
        lock.unlock()
        if Self.current === self { Self.current = nil }
        isActive = false
        isEventArbitrationActive = false
    }

    /// Runs on the multitouch framework's own callback thread — never hops
    /// to the main actor except (indirectly, via `onPinchDetected` above)
    /// when a gesture actually fires.
    nonisolated private func handleFrame(deviceID: Int32, samples: [TouchSample]) {
        lock.lock()
        guard deviceRouter.accepts(
            deviceID: deviceID,
            sampleCount: samples.count,
            hasUniqueIDs: Self.hasUniqueIDs(samples)
        ) else {
            lock.unlock()
            return
        }
        recognizer.ingest(samples)
        lock.unlock()
    }

    /// A frame carries at most a handful of contacts, so comparing them
    /// pairwise beats building a `Set` — this runs for every frame the
    /// trackpad reports, and the set was allocated purely to be counted and
    /// thrown away.
    nonisolated private static func hasUniqueIDs(_ samples: [TouchSample]) -> Bool {
        for i in samples.indices {
            for j in samples.index(after: i)..<samples.endIndex where samples[i].id == samples[j].id {
                return false
            }
        }
        return true
    }

    private static let frameCallback: MTContactCallbackFunction = { deviceID, rawData, nFingers, _, _ in
        guard nFingers >= 0, let trigger = current else { return 0 }
        var samples: [TouchSample] = []
        if let rawData, nFingers > 0 {
            let data = rawData.assumingMemoryBound(to: Finger.self)
            samples.reserveCapacity(Int(nFingers))
            for i in 0..<Int(nFingers) {
                let f = data[i]
                samples.append(TouchSample(id: f.identifier, x: f.normalized.position.x, y: f.normalized.position.y, size: f.size))
            }
        }
        // Empty/nil frames are meaningful: they release the current device
        // and re-arm the recognizer for the next gesture.
        trigger.handleFrame(deviceID: deviceID, samples: samples)
        return 0
    }
}
