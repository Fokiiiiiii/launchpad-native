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
    private var frameworkHandle: UnsafeMutableRawPointer?
    /// Pinch (fingers closing) — real Launchpad semantics: opens.
    private let onPinchClose: () -> Void
    /// Spread (fingers opening) — real Launchpad semantics: closes.
    private let onSpreadOpen: () -> Void
    public private(set) var isActive = false

    /// Not actor-isolated on purpose: `handleFrame` runs on whatever thread
    /// MultitouchSupport calls back on (not the main thread), and the
    /// framework may call back for multiple registered devices concurrently
    /// — `lock` protects `recognizer`'s mutable state across those calls.
    nonisolated(unsafe) private let recognizer: PinchGestureRecognizer
    private let lock = NSLock()

    /// The C callback has no context/refcon parameter to carry `self`
    /// through, so exactly one live trigger routes through this static
    /// reference — acceptable since the app only ever runs one.
    nonisolated(unsafe) private static var current: MultitouchGestureTrigger?

    /// `requiredContactCount` defaults to 3, per explicit user request — a
    /// 2-finger variant was tried and rejected earlier (collides with the
    /// far more universal system pinch-to-zoom gesture); this app no longer
    /// defaults to real Launchpad's own 4-finger (thumb+3) count.
    public init(
        onPinchClose: @escaping () -> Void,
        onSpreadOpen: @escaping () -> Void,
        sensitivity: Float = 0.6,
        requiredContactCount: Int = 3
    ) {
        self.onPinchClose = onPinchClose
        self.onSpreadOpen = onSpreadOpen
        self.recognizer = PinchGestureRecognizer(closingRatio: sensitivity, requiredContactCount: requiredContactCount)
    }

    @discardableResult
    public func start() -> Bool {
        guard deviceHandles.isEmpty else { return true }
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            DiagnosticsLog.triggers.error("MultitouchSupport dlopen failed; gesture trigger unavailable")
            return false
        }
        frameworkHandle = handle

        typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
        typealias MTRegisterFn = @convention(c) (UnsafeMutableRawPointer, MTContactCallbackFunction) -> Int32
        typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32

        guard let createListSym = dlsym(handle, "MTDeviceCreateList"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart") else {
            DiagnosticsLog.triggers.error("MultitouchSupport symbols missing; gesture trigger unavailable")
            return false
        }
        let createList = unsafeBitCast(createListSym, to: MTDeviceCreateListFn.self)
        let register = unsafeBitCast(registerSym, to: MTRegisterFn.self)
        let startDevice = unsafeBitCast(startSym, to: MTDeviceStartFn.self)

        guard let list = createList()?.takeRetainedValue() else {
            DiagnosticsLog.triggers.error("No multitouch devices found")
            return false
        }

        Self.current = self
        recognizer.onPinchDetected = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onPinchClose() }
        }
        recognizer.onSpreadDetected = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onSpreadOpen() }
        }

        let count = CFArrayGetCount(list)
        for i in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: ptr)
            _ = register(device, MultitouchGestureTrigger.frameCallback)
            _ = startDevice(device, 0)
            deviceHandles.append(device)
        }
        isActive = !deviceHandles.isEmpty
        return isActive
    }

    public func stop() {
        typealias MTDeviceStopFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
        if let handle = frameworkHandle, let stopSym = dlsym(handle, "MTDeviceStop") {
            let stopDevice = unsafeBitCast(stopSym, to: MTDeviceStopFn.self)
            for device in deviceHandles { _ = stopDevice(device) }
        }
        deviceHandles.removeAll()
        if Self.current === self { Self.current = nil }
        isActive = false
    }

    /// Runs on the multitouch framework's own callback thread — never hops
    /// to the main actor except (indirectly, via `onPinchDetected` above)
    /// when a gesture actually fires.
    nonisolated private func handleFrame(_ samples: [TouchSample]) {
        lock.lock()
        recognizer.ingest(samples)
        lock.unlock()
    }

    private static let frameCallback: MTContactCallbackFunction = { _, rawData, nFingers, _, _ in
        guard let rawData, nFingers >= 0, let trigger = current else { return 0 }
        let data = rawData.assumingMemoryBound(to: Finger.self)
        var samples: [TouchSample] = []
        samples.reserveCapacity(Int(nFingers))
        for i in 0..<Int(nFingers) {
            let f = data[i]
            samples.append(TouchSample(id: f.identifier, x: f.normalized.position.x, y: f.normalized.position.y, size: f.size))
        }
        trigger.handleFrame(samples)
        return 0
    }
}
