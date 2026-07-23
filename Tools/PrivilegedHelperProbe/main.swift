// Phase 8 part 4 manual verification: the daemon payload registered by
// PrivilegedHelperRegistrationProbe via SMAppService. Deliberately inert —
// it writes one line (its own euid + a timestamp) to a fixed /tmp path and
// exits immediately. No file is moved, deleted, or otherwise touched. This
// exists solely to prove (or disprove) that SMAppService daemon
// registration works at all for an ad-hoc-signed, unsigned-in-the-
// Developer-ID-sense build — real privileged removal logic is explicitly
// NOT implemented here or anywhere yet.
import Foundation

let logPath = "/tmp/launchpadnative-privileged-helper-probe.log"
let line = "euid=\(geteuid()) at \(Date())\n"
FileManager.default.createFile(atPath: logPath, contents: nil)
if let handle = FileHandle(forWritingAtPath: logPath) {
    handle.write(Data(line.utf8))
    handle.closeFile()
}
