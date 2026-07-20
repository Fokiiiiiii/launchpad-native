// Phase 5 pre-work (flagged in ReverseEngineering/Contracts/multitouch.md):
// captures real contact frames from this machine's trackpad to verify the
// community-documented `Finger` struct layout before writing a gesture
// recognizer against it, rather than trusting a reverse-engineered header
// outright.
import Foundation

typealias MTDeviceRef = UnsafeMutableRawPointer

struct MTPoint {
    var x: Float
    var y: Float
}

struct MTReadout {
    var position: MTPoint
    var velocity: MTPoint
}

// Community-documented layout (widely used across open-source multitouch
// tools referencing MultitouchSupport.framework). Verified here by dumping
// real frames and sanity-checking field ranges, not assumed.
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

guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
    print("FAIL: could not dlopen MultitouchSupport")
    exit(1)
}

typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
typealias MTRegisterFn = @convention(c) (MTDeviceRef, MTContactCallbackFunction) -> Int32
typealias MTDeviceStartFn = @convention(c) (MTDeviceRef, Int32) -> Int32
typealias MTDeviceStopFn = @convention(c) (MTDeviceRef) -> Int32

guard let createListSym = dlsym(handle, "MTDeviceCreateList"),
      let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
      let startSym = dlsym(handle, "MTDeviceStart"),
      let stopSym = dlsym(handle, "MTDeviceStop") else {
    print("FAIL: missing symbol")
    exit(1)
}

let createList = unsafeBitCast(createListSym, to: MTDeviceCreateListFn.self)
let register = unsafeBitCast(registerSym, to: MTRegisterFn.self)
let start = unsafeBitCast(startSym, to: MTDeviceStartFn.self)
let stop = unsafeBitCast(stopSym, to: MTDeviceStopFn.self)

guard let deviceList = createList()?.takeRetainedValue() else {
    print("FAIL: no devices")
    exit(1)
}

let deviceCount = CFArrayGetCount(deviceList)
print("Found \(deviceCount) multitouch device(s). Capturing for 15 seconds — touch the trackpad with a thumb + 3 fingers (Launchpad pinch gesture) now.")
print("(frame, nFingers) samples with finger detail on first frame of each contact count change:")

nonisolated(unsafe) var lastFingerCount: Int32 = -1

let callback: MTContactCallbackFunction = { device, rawData, nFingers, timestamp, frame in
    guard nFingers > 0, let rawData else { return 0 }
    if nFingers != lastFingerCount {
        lastFingerCount = nFingers
        let data = rawData.assumingMemoryBound(to: Finger.self)
        print("--- frame \(frame), \(nFingers) finger(s) ---")
        for i in 0..<Int(nFingers) {
            let f = data[i]
            print("  id=\(f.identifier) state=\(f.state) pos=(\(f.normalized.position.x), \(f.normalized.position.y)) size=\(f.size) angle=\(f.angle) major=\(f.majorAxis) minor=\(f.minorAxis)")
        }
    }
    return 0
}

for i in 0..<deviceCount {
    guard let devicePtr = CFArrayGetValueAtIndex(deviceList, i) else { continue }
    let device = UnsafeMutableRawPointer(mutating: devicePtr)
    _ = register(device, callback)
    _ = start(device, 0)
}

RunLoop.current.run(until: Date().addingTimeInterval(15))

for i in 0..<deviceCount {
    guard let devicePtr = CFArrayGetValueAtIndex(deviceList, i) else { continue }
    let device = UnsafeMutableRawPointer(mutating: devicePtr)
    _ = stop(device)
}

print("Done.")
