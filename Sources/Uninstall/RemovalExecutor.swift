import AppKit
import Diagnostics
import Foundation

/// The result of attempting to act on one `RemovalItem`.
public struct RemovalOutcome: Sendable {
    public let item: RemovalItem
    public let succeeded: Bool
    public let errorDescription: String?

    public init(item: RemovalItem, succeeded: Bool, errorDescription: String?) {
        self.item = item
        self.succeeded = succeeded
        self.errorDescription = errorDescription
    }
}

/// Executes a removal plan — but only the slice of it this phase considers
/// safe: `owned` items that don't need a Privileged Helper. Everything else
/// is refused, even if it somehow reached this function, because deletion
/// here always means moving to Trash (reversible), never `removeItem`
/// (permanent). `sharedRisk`/`unknown`/privileged-helper items get a
/// `succeeded: false` outcome explaining why, not silent skipping — the
/// caller (Settings UI) surfaces that in the operation report.
public enum RemovalExecutor {
    public static func execute(_ items: [RemovalItem]) -> [RemovalOutcome] {
        items.map(executeOne)
    }

    /// Terminates every running instance of `bundleIdentifier`, if any —
    /// call this before trashing the bundle itself, since moving a running
    /// app's executable out from under it leaves a broken process behind.
    /// Tries a graceful `terminate()` first, then `forceTerminate()` only if
    /// that's refused.
    @discardableResult
    public static func terminateIfRunning(bundleIdentifier: String) -> Bool {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard !runningApps.isEmpty else { return true }
        var allTerminated = true
        for app in runningApps {
            if !app.terminate() {
                if !app.forceTerminate() {
                    allTerminated = false
                }
            }
        }
        return allTerminated
    }

    private static func executeOne(_ item: RemovalItem) -> RemovalOutcome {
        guard item.classification == .owned, !item.requiresPrivilegedHelper else {
            return RemovalOutcome(
                item: item,
                succeeded: false,
                errorDescription: "requires manual removal (shared risk / unknown / needs a Privileged Helper this phase doesn't implement)"
            )
        }

        guard FileManager.default.fileExists(atPath: item.path.path) else {
            // Already gone — not an error, there's simply nothing left to do.
            return RemovalOutcome(item: item, succeeded: true, errorDescription: nil)
        }

        if isUserLaunchAgent(item.path) {
            unloadUserLaunchAgent(at: item.path)
        }

        do {
            try FileManager.default.trashItem(at: item.path, resultingItemURL: nil)
            return RemovalOutcome(item: item, succeeded: true, errorDescription: nil)
        } catch {
            DiagnosticsLog.uninstall.error("Failed to trash \(item.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return RemovalOutcome(item: item, succeeded: false, errorDescription: error.localizedDescription)
        }
    }

    private static func isUserLaunchAgent(_ url: URL) -> Bool {
        url.pathExtension == "plist" && url.path.contains("/Library/LaunchAgents/")
    }

    /// `launchctl bootout` is the public CLI tool for unregistering a user
    /// LaunchAgent from launchd — not a private API. Best-effort: if the
    /// plist can't be parsed or the agent was never loaded, this silently
    /// does nothing and the Trash move below still proceeds (the plist file
    /// itself is the thing being removed either way).
    private static func unloadUserLaunchAgent(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String else { return }
        let uid = getuid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(uid)/\(label)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
