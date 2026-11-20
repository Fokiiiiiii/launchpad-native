import Foundation
import Testing
@testable import Uninstall

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

@Suite("RemovalExecutor")
struct RemovalExecutorTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("an owned, non-privileged file is moved to Trash")
    func ownedItemIsTrashed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("owned.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)

        let item = RemovalItem(path: file, classification: .owned, requiresPrivilegedHelper: false)
        let outcomes = RemovalExecutor.execute([item], allowedRoots: [dir])

        #expect(outcomes.count == 1)
        #expect(outcomes[0].succeeded == true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("sharedRisk items are never touched")
    func sharedRiskItemIsUntouched() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("shared.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)

        let item = RemovalItem(path: file, classification: .sharedRisk, requiresPrivilegedHelper: false)
        let outcomes = RemovalExecutor.execute([item], allowedRoots: [dir])

        #expect(outcomes.count == 1)
        #expect(outcomes[0].succeeded == false)
        #expect(outcomes[0].errorDescription != nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("unknown items are never touched")
    func unknownItemIsUntouched() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("unknown.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)

        let item = RemovalItem(path: file, classification: .unknown, requiresPrivilegedHelper: false)
        let outcomes = RemovalExecutor.execute([item], allowedRoots: [dir])

        #expect(outcomes[0].succeeded == false)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("owned items requiring a privileged helper are never touched")
    func privilegedHelperItemIsUntouched() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("privileged.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)

        let item = RemovalItem(path: file, classification: .owned, requiresPrivilegedHelper: true)
        let outcomes = RemovalExecutor.execute([item], allowedRoots: [dir])

        #expect(outcomes[0].succeeded == false)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a nonexistent owned path is treated as already-removed, not an error")
    func nonexistentPathSucceedsAsNoOp() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let item = RemovalItem(path: missing, classification: .owned, requiresPrivilegedHelper: false)
        let outcomes = RemovalExecutor.execute([item], allowedRoots: [dir])

        #expect(outcomes[0].succeeded == true)
        #expect(outcomes[0].errorDescription == nil)
    }

    @Test("a mixed plan only acts on the owned, non-privileged item")
    func mixedPlanOnlyActsOnOwnedItem() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ownedFile = dir.appendingPathComponent("owned.txt")
        let sharedFile = dir.appendingPathComponent("shared.txt")
        try "owned".write(to: ownedFile, atomically: true, encoding: .utf8)
        try "shared".write(to: sharedFile, atomically: true, encoding: .utf8)

        let plan = [
            RemovalItem(path: ownedFile, classification: .owned, requiresPrivilegedHelper: false),
            RemovalItem(path: sharedFile, classification: .sharedRisk, requiresPrivilegedHelper: false)
        ]
        let outcomes = RemovalExecutor.execute(plan, allowedRoots: [dir])

        #expect(outcomes.filter(\.succeeded).count == 1)
        #expect(!FileManager.default.fileExists(atPath: ownedFile.path))
        #expect(FileManager.default.fileExists(atPath: sharedFile.path))
    }

    // MARK: Where a removal may act

    /// The plan is built from text an app wrote about itself, so the executor
    /// checks the place again rather than trusting the plan.
    @Test("a path outside the allowed locations is refused and left alone")
    func pathOutsideAllowedLocationsIsRefused() throws {
        let allowed = try makeTempDir()
        let elsewhere = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: allowed)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let file = elsewhere.appendingPathComponent("precious.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)

        let item = RemovalItem(path: file, classification: .owned, requiresPrivilegedHelper: false)
        let outcomes = RemovalExecutor.execute([item], allowedRoots: [allowed])

        #expect(outcomes[0].succeeded == false)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a path that climbs out with .. is refused even if it lands in an allowed place")
    func parentTraversalIsRefused() throws {
        let allowed = try makeTempDir()
        let elsewhere = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: allowed)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let victim = elsewhere.appendingPathComponent("victim.txt")
        try "data".write(to: victim, atomically: true, encoding: .utf8)
        // allowed/../<elsewhere>/victim.txt — written the way a hostile
        // identifier would build it.
        let sneaky = allowed
            .appendingPathComponent("..")
            .appendingPathComponent(elsewhere.lastPathComponent)
            .appendingPathComponent("victim.txt")

        let outcomes = RemovalExecutor.execute(
            [RemovalItem(path: sneaky, classification: .owned, requiresPrivilegedHelper: false)],
            allowedRoots: [allowed.deletingLastPathComponent()]
        )

        #expect(outcomes[0].succeeded == false)
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test("an app bundle may be removed from wherever it is")
    func appBundleIsPermittedAnywhere() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = dir.appendingPathComponent("Thing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let outcomes = RemovalExecutor.execute(
            [RemovalItem(path: bundle, classification: .owned, requiresPrivilegedHelper: false)],
            allowedRoots: []
        )

        #expect(outcomes[0].succeeded == true)
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
    }

    @Test("the default locations are the app-data folders, never Library itself or the rest of home")
    func defaultLocations() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = RemovalExecutor.defaultAllowedRoots
        let library = home.appendingPathComponent("Library")

        #expect(RemovalExecutor.isPermittedTarget(library.appendingPathComponent("Preferences/com.example.plist"), allowedRoots: roots))
        #expect(RemovalExecutor.isPermittedTarget(library.appendingPathComponent("Application Support/com.example"), allowedRoots: roots))
        #expect(!RemovalExecutor.isPermittedTarget(library.appendingPathComponent("Preferences"), allowedRoots: roots))
        #expect(!RemovalExecutor.isPermittedTarget(library, allowedRoots: roots))
        #expect(!RemovalExecutor.isPermittedTarget(home.appendingPathComponent("Documents"), allowedRoots: roots))
        #expect(!RemovalExecutor.isPermittedTarget(
            library.appendingPathComponent("Application Support/../../Documents"), allowedRoots: roots
        ))
    }

    // MARK: Order of a confirmed removal

    @Test("nothing selected asks nothing of the app and nothing of the disk")
    func nothingSelectedDoesNothing() async {
        let asked = Flag()
        let run = await RemovalCoordinator.run(
            items: [],
            bundleURL: URL(fileURLWithPath: "/tmp/Whatever.app"),
            bundleIdentifier: "com.example.whatever",
            terminate: { _, _ in asked.set(); return .terminated }
        )

        #expect(run.status == .nothingSelected)
        #expect(run.outcomes.isEmpty)
        #expect(!asked.isSet)
    }

    /// Moving the files of an app that is still writing them races whatever it
    /// writes on the way out.
    @Test("an app that has not quit stops the removal before any file is moved")
    func runningAppBlocksRemoval() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("data.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)

        let run = await RemovalCoordinator.run(
            items: [RemovalItem(path: file, classification: .owned, requiresPrivilegedHelper: false)],
            bundleURL: dir.appendingPathComponent("Busy.app"),
            bundleIdentifier: "com.example.busy",
            allowedRoots: [dir],
            terminate: { _, _ in .stillRunning }
        )

        #expect(run.status == .blockedByRunningApp)
        #expect(run.outcomes.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("once the app has quit the selected items are moved")
    func quitAppAllowsRemoval() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("data.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)

        let run = await RemovalCoordinator.run(
            items: [RemovalItem(path: file, classification: .owned, requiresPrivilegedHelper: false)],
            bundleURL: dir.appendingPathComponent("Quit.app"),
            bundleIdentifier: "com.example.quit",
            allowedRoots: [dir],
            terminate: { _, _ in .terminated }
        )

        #expect(run.status == .completed)
        #expect(run.outcomes.map(\.succeeded) == [true])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Cancel

    /// Closing the panel is Cancel. A removal that was waiting for the app to quit
    /// used to carry on behind the closed panel and move the files once it had.
    @Test("cancelling while the app is quitting moves nothing")
    func cancelWhileWaitingMovesNothing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("data.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)
        let waiting = Flag()

        let removal = Task {
            await RemovalCoordinator.run(
                items: [RemovalItem(path: file, classification: .owned, requiresPrivilegedHelper: false)],
                bundleURL: dir.appendingPathComponent("Slow.app"),
                bundleIdentifier: "com.example.slow",
                allowedRoots: [dir],
                terminate: { _, _ in
                    waiting.set()
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
                    return .terminated
                }
            )
        }
        while !waiting.isSet { try await Task.sleep(nanoseconds: 5_000_000) }
        removal.cancel()
        let run = await removal.value

        #expect(run.status == .cancelled)
        #expect(run.outcomes.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: LaunchAgents

    private func makeAgentItems(in dir: URL) throws -> (data: RemovalItem, agent: RemovalItem) {
        let data = dir.appendingPathComponent("data.txt")
        try "data".write(to: data, atomically: true, encoding: .utf8)
        let agents = dir.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = agents.appendingPathComponent("com.example.helper.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": "com.example.helper"], format: .xml, options: 0).write(to: plist)
        return (
            RemovalItem(path: data, classification: .owned, requiresPrivilegedHelper: false),
            RemovalItem(path: plist, classification: .owned, requiresPrivilegedHelper: false)
        )
    }

    /// The plan lists an app's data before its agents. A helper left running while
    /// its folders were emptied could write into them again.
    @Test("selected LaunchAgents are stopped before any file is moved")
    func agentsAreStoppedFirst() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (data, agent) = try makeAgentItems(in: dir)
        var dataWasStillThere: Bool?

        let outcomes = RemovalExecutor.execute([data, agent], allowedRoots: [dir], stopAgent: { _ in
            dataWasStillThere = FileManager.default.fileExists(atPath: data.path.path)
            return .stopped
        })

        #expect(dataWasStillThere == true)
        #expect(outcomes.map(\.succeeded) == [true, true])
    }

    /// Moving the plist of a job that is still running leaves it running with
    /// nothing to say it exists, and the report called that a success.
    @Test("an agent that could not be stopped keeps its file and is reported failed")
    func agentThatWillNotStopIsLeftInPlace() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (data, agent) = try makeAgentItems(in: dir)

        let outcomes = RemovalExecutor.execute([data, agent], allowedRoots: [dir], stopAgent: { _ in .failed })

        #expect(outcomes.map(\.succeeded) == [true, false])
        #expect(FileManager.default.fileExists(atPath: agent.path.path))
        #expect(!FileManager.default.fileExists(atPath: data.path.path))
    }

    @Test("a LaunchAgent is stopped only when it is loaded, and a failed stop is a failure")
    func stoppingAnAgentReadsTheLaunchctlResults() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, agent) = try makeAgentItems(in: dir)

        func stop(_ results: [String: Int32?]) -> (RemovalExecutor.AgentStopResult, [String]) {
            var called: [String] = []
            let result = RemovalExecutor.stopUserLaunchAgent(at: agent.path, launchctl: { arguments in
                called.append(arguments[0])
                return results[arguments[0]] ?? nil
            })
            return (result, called)
        }

        let notLoaded = stop(["print": 113])
        #expect(notLoaded.0 == .notLoaded)
        #expect(notLoaded.1 == ["print"])
        #expect(stop(["print": 0, "bootout": 0]).0 == .stopped)
        #expect(stop(["print": 0, "bootout": 5]).0 == .failed)
        #expect(stop([:]).0 == .failed)

        let unlabelled = dir.appendingPathComponent("Library/LaunchAgents/none.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Other": 1], format: .xml, options: 0).write(to: unlabelled)
        #expect(RemovalExecutor.stopUserLaunchAgent(at: unlabelled, launchctl: { _ in 0 }) == .notLoaded)
    }

    // MARK: Which bundle is running

    /// The catalog can hold a link to an app that lives outside the scanned
    /// folders, while the running app reports where it really is.
    @Test("a link to an app is the same bundle as the app it points at")
    func linkAndTargetAreTheSameBundle() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("Real.app", isDirectory: true)
        let other = dir.appendingPathComponent("Other.app", isDirectory: true)
        let link = dir.appendingPathComponent("Link.app")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(RemovalExecutor.isSameBundle(real, link))
        #expect(RemovalExecutor.isSameBundle(link, real))
        #expect(!RemovalExecutor.isSameBundle(other, link))
        #expect(!RemovalExecutor.isSameBundle(nil, link))
    }
}
