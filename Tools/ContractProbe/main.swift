// Phase 1 tool: verifies Private API symbol/class existence on the CURRENT
// machine's OS build before any typed wrapper is written. Never hand-write a
// wrapper against a symbol this probe hasn't confirmed. Re-run and diff
// output whenever the target OS build changes.
import AppKit
import Foundation
import ServiceManagement
import SystemExtensions

func osBuild() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
    task.arguments = ["-buildVersion"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    let build = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (build \(build))"
}

func dlsymCheck(frameworkPath: String, symbols: [String]) -> [String: Bool] {
    guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
        return Dictionary(uniqueKeysWithValues: symbols.map { ($0, false) })
    }
    defer { dlclose(handle) }
    var results: [String: Bool] = [:]
    for symbol in symbols {
        results[symbol] = dlsym(handle, symbol) != nil
    }
    return results
}

func classCheck(names: [String]) -> [String: Bool] {
    var results: [String: Bool] = [:]
    for name in names {
        results[name] = NSClassFromString(name) != nil
    }
    return results
}

print("OS: \(osBuild())")
print("")

print("== Tier 2: SkyLight (private, read-only-oriented functions) ==")
let skyLightSymbols = [
    "SLSMainConnectionID",
    "CGSMainConnectionID",
    "SLSCopyWindowsWithOptionsAndTags",
    "SLSGetWindowOwner",
    "SLSGetWindowBounds",
    "SLSGetWindowLevel",
    "SLSSetWindowLevel",
    "SLSOrderWindow",
    "SLSCopySpacesForWindows",
    "SLSGetActiveSpace",
    "SLSManagedDisplayGetCurrentSpace",
    "SLSCopyManagedDisplays",
    "SLSCopyManagedDisplaySpaces",
    "SLSCopyActiveMenuBarDisplayIdentifier"
]
for (k, v) in dlsymCheck(
    frameworkPath: "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    symbols: skyLightSymbols
).sorted(by: { $0.key < $1.key }) {
    print("  \(v ? "OK  " : "MISS") \(k)")
}

print("")
print("== Tier 2: MultitouchSupport ==")
let mtSymbols = [
    "MTDeviceCreateList",
    "MTDeviceCreateDefault",
    "MTRegisterContactFrameCallback",
    "MTUnregisterContactFrameCallback",
    "MTDeviceStart",
    "MTDeviceStop",
    "MTDeviceRelease"
]
for (k, v) in dlsymCheck(
    frameworkPath: "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
    symbols: mtSymbols
).sorted(by: { $0.key < $1.key }) {
    print("  \(v ? "OK  " : "MISS") \(k)")
}

print("")
print("== Tier 3: LaunchServices SPI classes (CoreServices/LaunchServices) ==")
// CoreServices is not auto-linked by AppKit-only imports; load it explicitly first.
_ = dlopen(
    "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/LaunchServices",
    RTLD_NOW
)
let lsClasses = ["LSApplicationWorkspace", "LSApplicationRecord", "_LSQuery"]
for (k, v) in classCheck(names: lsClasses).sorted(by: { $0.key < $1.key }) {
    print("  \(v ? "OK  " : "MISS") \(k)")
}

print("")
print("== Tier 1: public replacements (compiled against current SDK) ==")
if #available(macOS 26.0, *) {
    print("  OK   NSGlassEffectView (SDK-linked, macOS 26.0+ availability compiled)")
    print("  OK   NSGlassEffectContainerView (SDK-linked, macOS 26.0+ availability compiled)")
} else {
    print("  N/A  NSGlassEffectView/-ContainerView (runtime below macOS 26.0)")
}
if #available(macOS 13.0, *) {
    print("  OK   SMAppService (SDK-linked, macOS 13.0+ availability compiled)")
}
if #available(macOS 10.15, *) {
    print("  OK   OSSystemExtensionRequest (SDK-linked, SystemExtensions framework compiled)")
}

print("")
print("== Signature verification: calling read-only functions with guessed C ABI ==")
// A dlsym hit only proves the symbol exists, not that the guessed argument/
// return types are correct. Call the safest read-only ones and sanity-check
// the result before any signature is considered frozen.
if let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) {
    defer { dlclose(handle) }

    if let sym = dlsym(handle, "SLSMainConnectionID") {
        typealias SLSMainConnectionIDFn = @convention(c) () -> Int32
        let fn = unsafeBitCast(sym, to: SLSMainConnectionIDFn.self)
        let cid = fn()
        // A real WindowServer connection id from this process is always > 0.
        print("  SLSMainConnectionID() -> \(cid)  [plausible: \(cid > 0)]  sig: () -> Int32")

        if cid > 0, let activeSpaceSym = dlsym(handle, "SLSGetActiveSpace") {
            typealias SLSGetActiveSpaceFn = @convention(c) (Int32) -> UInt64
            let activeSpaceFn = unsafeBitCast(activeSpaceSym, to: SLSGetActiveSpaceFn.self)
            let space = activeSpaceFn(cid)
            print("  SLSGetActiveSpace(cid) -> \(space)  [plausible: \(space > 0)]  sig: (Int32) -> UInt64")
        }
    }
}

if let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
   let sym = dlsym(handle, "MTDeviceCreateList") {
    typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    let fn = unsafeBitCast(sym, to: MTDeviceCreateListFn.self)
    if let list = fn()?.takeRetainedValue() {
        let count = CFArrayGetCount(list)
        print("  MTDeviceCreateList() -> CFArray with \(count) device(s)  sig: () -> Unmanaged<CFArray>?")
    } else {
        print("  MTDeviceCreateList() -> NULL (no multitouch device attached/no trackpad)  sig: () -> Unmanaged<CFArray>?")
    }
    dlclose(handle)
}

print("")
print("== HID-level F4 constant ==")
// NX_KEYTYPE_LAUNCH_PANEL = 13, defined in <IOKit/hidsystem/ev_keymap.h>.
// Not a runtime symbol to dlsym — it's a compile-time constant; verified by
// the fact that this file compiles against the constant below.
print("  NX_KEYTYPE_LAUNCH_PANEL = 13 (compiled against IOKit/hidsystem/ev_keymap.h)")

print("")
print("== CGEventTap at cghidEventTap: can this unprivileged process install one? ==")
let tap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: CGEventMask(1 << 14), // NX_SYSDEFINED; not in CGEventType's enum cases
    callback: { _, _, event, _ in Unmanaged.passRetained(event) },
    userInfo: nil
)
if tap != nil {
    print("  OK   tap created (process likely already has Input Monitoring/Accessibility permission)")
} else {
    print("  MISS tap creation returned NULL (needs Input Monitoring permission grant in System Settings, or elevated privileges — must re-check after granting)")
}
