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
}
