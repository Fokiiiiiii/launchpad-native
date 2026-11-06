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

/// How asking a running app to quit ended.
public enum TerminationResult: Sendable, Equatable {
    case notRunning
    case terminated
    /// Still running when the wait ran out: it declined, or is waiting on the
    /// user (an unsaved document).
    case stillRunning
}

/// Executes a removal plan — but only the slice of it this phase considers
/// safe: `owned` items that don't need a Privileged Helper. Everything else
/// is refused, even if it somehow reached this function, because deletion
/// here always means moving to Trash (reversible), never `removeItem`
/// (permanent). `sharedRisk`/`unknown`/privileged-helper items get a
/// `succeeded: false` outcome explaining why, not silent skipping — the
/// caller (Settings UI) surfaces that in the operation report.
public enum RemovalExecutor {
    /// Where an app's own data lives for a user-level removal. A target has to
    /// sit strictly inside one of these (or be an `.app` bundle): the plan is
    /// built from text an app wrote about itself, so the executor checks again
    /// instead of trusting that every path in it is where it should be.
    public static var defaultAllowedRoots: [URL] {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return [
            "Application Support", "Caches", "Preferences", "Containers", "Saved Application State",
            "WebKit", "HTTPStorages", "Cookies", "Logs", "Application Scripts", "LaunchAgents",
        ].map { library.appendingPathComponent($0, isDirectory: true) }
    }

    public static func execute(
        _ items: [RemovalItem],
        allowedRoots: [URL] = RemovalExecutor.defaultAllowedRoots
    ) -> [RemovalOutcome] {
        items.map { executeOne($0, allowedRoots: allowedRoots) }
    }

    /// Whether `url` is somewhere a removal may act: an `.app` bundle, or
    /// strictly inside one of `allowedRoots`. A path that climbs with `..` is
    /// refused outright, so it cannot be dressed up as being inside one.
    public static func isPermittedTarget(_ url: URL, allowedRoots: [URL]) -> Bool {
        guard !url.pathComponents.contains("..") else { return false }
        if url.pathExtension.lowercased() == "app" { return true }
        let path = url.standardizedFileURL.path
        return allowedRoots.contains { root in
            let rootPath = root.standardizedFileURL.path
            return path.count > rootPath.count + 1 && path.hasPrefix(rootPath + "/")
        }
    }

    /// Asks every running copy of the app at `bundleURL` to quit and waits
    /// until they have.
    ///
    /// `terminate()` only reports that the request was sent — the app may
    /// still be showing a save prompt — so moving its files straight away would
    /// race whatever it writes on the way out. This does not force anything: an
    /// app that has not quit when the wait ends is reported as such, and the
    /// caller stops.
    ///
    /// Only the copy at `bundleURL` is asked, not every process that happens to
    /// share the bundle identifier.
    public static func terminateAndWait(
        bundleURL: URL,
        bundleIdentifier: String,
        timeout: TimeInterval = 5
    ) async -> TerminationResult {
        let target = bundleURL.standardizedFileURL
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.bundleURL?.standardizedFileURL == target }
        guard !running.isEmpty else { return .notRunning }
        for app in running { _ = app.terminate() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if running.allSatisfy({ $0.isTerminated }) { return .terminated }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return running.allSatisfy { $0.isTerminated } ? .terminated : .stillRunning
    }

    private static func executeOne(_ item: RemovalItem, allowedRoots: [URL]) -> RemovalOutcome {
        guard item.classification == .owned, !item.requiresPrivilegedHelper else {
            return RemovalOutcome(
                item: item,
                succeeded: false,
                errorDescription: "requires manual removal (shared risk / unknown / needs a Privileged Helper this phase doesn't implement)"
            )
        }

        guard isPermittedTarget(item.path, allowedRoots: allowedRoots) else {
            DiagnosticsLog.uninstall.error("Refusing to remove a path outside the allowed locations: \(item.path.path, privacy: .private)")
            return RemovalOutcome(item: item, succeeded: false, errorDescription: "outside the locations an app's data is kept in")
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

/// What a confirmed removal did.
public struct RemovalRun: Sendable {
    public enum Status: Sendable, Equatable {
        /// Nothing was selected, so nothing was asked of the app or the disk.
        case nothingSelected
        /// The app had not quit, so no file was moved.
        case blockedByRunningApp
        case completed
    }

    public let status: Status
    public let outcomes: [RemovalOutcome]

    public init(status: Status, outcomes: [RemovalOutcome]) {
        self.status = status
        self.outcomes = outcomes
    }
}

/// The steps of a confirmed removal, in the order they must happen: the app
/// has to be gone before its files are moved. Runs off the main actor — the
/// caller only awaits the result.
public enum RemovalCoordinator {
    public static func run(
        items: [RemovalItem],
        bundleURL: URL,
        bundleIdentifier: String,
        allowedRoots: [URL] = RemovalExecutor.defaultAllowedRoots,
        terminate: @Sendable (URL, String) async -> TerminationResult = { url, identifier in
            await RemovalExecutor.terminateAndWait(bundleURL: url, bundleIdentifier: identifier)
        }
    ) async -> RemovalRun {
        guard !items.isEmpty else { return RemovalRun(status: .nothingSelected, outcomes: []) }
        if await terminate(bundleURL, bundleIdentifier) == .stillRunning {
            return RemovalRun(status: .blockedByRunningApp, outcomes: [])
        }
        return RemovalRun(status: .completed, outcomes: RemovalExecutor.execute(items, allowedRoots: allowedRoots))
    }
}
