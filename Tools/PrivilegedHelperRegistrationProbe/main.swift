// Phase 8 part 4 manual verification: does SMAppService daemon
// registration actually work for an ad-hoc-signed (no paid Developer ID)
// build? This project is unsigned/unnotarized by explicit requirement, so
// this has to be checked on real hardware rather than assumed either way.
//
// Run against a copy of LaunchpadNative.app assembled by
// Scripts/build-privileged-helper-fixture.sh (which embeds the
// PrivilegedHelperProbe daemon + its launchd plist under
// Contents/Library/LaunchDaemons/ and ad-hoc codesigns the bundle), e.g.:
//   ~/.cache/launchpad-native/build/LaunchpadNative.app/Contents/MacOS/PrivilegedHelperRegistrationProbe
//
// The daemon payload itself is deliberately inert (writes one log line,
// see PrivilegedHelperProbe/main.swift) — this tool only proves whether
// registration + real root execution happens at all. It always unregisters
// at the end so no daemon is left behind on this machine.
import Foundation
import ServiceManagement

let label = "com.launchpadnative.privilegedhelperprobe"
let logPath = "/tmp/launchpadnative-privileged-helper-probe.log"
try? FileManager.default.removeItem(atPath: logPath)

func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "failed to launch \(path): \(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

print("Codesign identity on this bundle:")
// Bundle.main.bundlePath for a plain executable resolves to its containing
// directory (.../LaunchpadNative.app/Contents/MacOS) since this tool has no
// Info.plist of its own — walk up two levels to the real .app root.
let bundlePath = Bundle.main.bundlePath
let mainAppPath = URL(fileURLWithPath: bundlePath).deletingLastPathComponent().deletingLastPathComponent().path
print(run("/usr/bin/codesign", ["-dv", mainAppPath]).output)

let service = SMAppService.daemon(plistName: "\(label).plist")
print("\nStatus before register(): \(service.status)")

do {
    try service.register()
    print("register() succeeded. Status: \(service.status)")
} catch {
    print("register() FAILED: \(error)")
    print("\n(This is the real-world answer: SMAppService daemon registration does not work for this build's code-signing configuration.)")
    exit(0)
}

// Give launchd a moment to actually start the daemon.
Thread.sleep(forTimeInterval: 2)

print("\nlaunchctl print system/\(label):")
let printResult = run("/bin/launchctl", ["print", "system/\(label)"])
print(printResult.output.isEmpty ? "(empty output, exit code \(printResult.status))" : printResult.output)

print("\nLog file at \(logPath):")
if let contents = try? String(contentsOfFile: logPath, encoding: .utf8) {
    print(contents)
    print("=> The daemon actually ran. This proves SMAppService registration is viable on this machine's code-signing setup.")
} else {
    print("(missing — the daemon registered but never actually ran)")
}

print("\nUnregistering...")
do {
    try service.unregister()
    print("unregister() succeeded.")
} catch {
    print("unregister() FAILED: \(error) — manual cleanup may be needed: sudo launchctl bootout system/\(label)")
}

Thread.sleep(forTimeInterval: 1)
print("\nlaunchctl print system/\(label) after unregister (should be empty/error):")
print(run("/bin/launchctl", ["print", "system/\(label)"]).output)
