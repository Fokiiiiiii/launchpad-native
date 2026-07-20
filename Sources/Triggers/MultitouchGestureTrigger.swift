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

/// Raw multitouch Launchpad-pinch trigger. Build-gated: if the private
/// framework or its symbols aren't present, `start()` returns `false` and
/// every other trigger keeps working (capability-level fail isolation).
@MainActor
public final class MultitouchGestureTrigger {
    private var deviceHandles: [UnsafeMutableRawPointer] = []
    private var frameworkHandle: UnsafeMutableRawPointer?
    private let recognizer: PinchGestureRecognizer
    private let onActivate: () -> Void
    public private(set) var isActive = false

    /// The C callback has no context/refcon parameter to carry `self`
    /// through, so exactly one live trigger routes through this static
    /// reference — acceptable since the app only ever runs one.
    nonisolated(unsafe) private static var current: MultitouchGestureTrigger?

    public init(onActivate: @escaping () -> Void, sensitivity: Float = 0.6) {
        self.onActivate = onActivate
        self.recognizer = PinchGestureRecognizer(closingRatio: sensitivity)
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
        recognizer.onPinchDetected = { [weak self] in self?.onActivate() }

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

    private static let frameCallback: MTContactCallbackFunction = { _, rawData, nFingers, _, _ in
        guard let rawData, nFingers >= 0 else { return 0 }
        let data = rawData.assumingMemoryBound(to: Finger.self)
        var samples: [TouchSample] = []
        samples.reserveCapacity(Int(nFingers))
        for i in 0..<Int(nFingers) {
            let f = data[i]
            samples.append(TouchSample(id: f.identifier, x: f.normalized.position.x, y: f.normalized.position.y, size: f.size))
        }
        Task { @MainActor in
            current?.recognizer.ingest(samples)
        }
        return 0
    }
}
