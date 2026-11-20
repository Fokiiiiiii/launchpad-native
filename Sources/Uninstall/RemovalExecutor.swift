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

    /// How asking launchd to stop one user LaunchAgent ended.
    public enum AgentStopResult: Sendable, Equatable {
        case stopped
        /// Not running, or the plist names no job: nothing to stop.
        case notLoaded
        /// It is running and could not be stopped.
        case failed
    }

    /// Stops the selected LaunchAgents before any file is moved, so a helper that
    /// keeps running is not left writing into folders that are being emptied.
    /// An agent that could not be stopped keeps its file in place and is reported
    /// as failed: moving the plist to the Trash would leave the job running with
    /// nothing to say it exists.
    public static func execute(
        _ items: [RemovalItem],
        allowedRoots: [URL] = RemovalExecutor.defaultAllowedRoots,
        stopAgent: ((URL) -> AgentStopResult)? = nil
    ) -> [RemovalOutcome] {
        var notStopped: Set<URL> = []
        for item in items where isRemovable(item, allowedRoots: allowedRoots) && isUserLaunchAgent(item.path) {
            let result = stopAgent.map { $0(item.path) } ?? stopUserLaunchAgent(at: item.path)
            if result == .failed { notStopped.insert(item.path) }
        }
        return items.map { item in
            guard !notStopped.contains(item.path) else {
                return RemovalOutcome(
                    item: item,
                    succeeded: false,
                    errorDescription: "the agent is running and could not be stopped, so its file was left in place"
                )
            }
            return executeOne(item, allowedRoots: allowedRoots)
        }
    }

    /// Whether `execute` would act on this item: owned, in the user's domain,
    /// somewhere removal is allowed, and still there.
    private static func isRemovable(_ item: RemovalItem, allowedRoots: [URL]) -> Bool {
        item.classification == .owned
            && !item.requiresPrivilegedHelper
            && isPermittedTarget(item.path, allowedRoots: allowedRoots)
            && FileManager.default.fileExists(atPath: item.path.path)
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
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { isSameBundle($0.bundleURL, bundleURL) }
        guard !running.isEmpty else { return .notRunning }
        for app in running { _ = app.terminate() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if running.allSatisfy({ $0.isTerminated }) { return .terminated }
            // A cancelled sleep returns at once, so without this the loop spins
            // until the deadline.
            guard !Task.isCancelled else { return .stillRunning }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return running.allSatisfy { $0.isTerminated } ? .terminated : .stillRunning
    }

    /// Whether two URLs name the same bundle on disk. The catalog can hold the link
    /// to an app that lives outside the scanned folders, while a running app
    /// reports the real location, and comparing the two as written called a
    /// running app not running.
    static func isSameBundle(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.resolvingSymlinksInPath().standardizedFileURL == rhs.resolvingSymlinksInPath().standardizedFileURL
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

    /// Stops a user LaunchAgent with `launchctl`, the public CLI for it. It is
    /// asked first whether the job is loaded at all, because `bootout` of one that
    /// is not fails too, and that is not a failure to stop anything.
    static func stopUserLaunchAgent(
        at url: URL,
        launchctl: ([String]) -> Int32? = { runLaunchctl($0) }
    ) -> AgentStopResult {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String else { return .notLoaded }
        let target = "gui/\(getuid())/\(label)"
        guard let printed = launchctl(["print", target]) else { return .failed }
        guard printed == 0 else { return .notLoaded }
        return launchctl(["bootout", target]) == 0 ? .stopped : .failed
    }

    /// Runs `/bin/launchctl`, with its output discarded and a limit on the wait.
    /// Returns nil if it could not be run or did not finish in time.
    private static func runLaunchctl(_ arguments: [String], timeout: TimeInterval = 5) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        return process.terminationStatus
    }
}

/// What a confirmed removal did.
public struct RemovalRun: Sendable {
    public enum Status: Sendable, Equatable {
        /// Nothing was selected, so nothing was asked of the app or the disk.
        case nothingSelected
        /// The app had not quit, so no file was moved.
        case blockedByRunningApp
        /// The panel was closed while this waited for the app to quit.
        case cancelled
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
        let termination = await terminate(bundleURL, bundleIdentifier)
        // Checked before the files are touched: closing the panel is Cancel, and
        // it used to leave the removal running behind it.
        if Task.isCancelled { return RemovalRun(status: .cancelled, outcomes: []) }
        if termination == .stillRunning {
            return RemovalRun(status: .blockedByRunningApp, outcomes: [])
        }
        return RemovalRun(status: .completed, outcomes: RemovalExecutor.execute(items, allowedRoots: allowedRoots))
    }
}
