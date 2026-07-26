import Foundation
import Testing
@testable import Uninstall

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
        let outcomes = RemovalExecutor.execute([item])

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
        let outcomes = RemovalExecutor.execute([item])

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
        let outcomes = RemovalExecutor.execute([item])

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
        let outcomes = RemovalExecutor.execute([item])

        #expect(outcomes[0].succeeded == false)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a nonexistent owned path is treated as already-removed, not an error")
    func nonexistentPathSucceedsAsNoOp() {
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")
        let item = RemovalItem(path: missing, classification: .owned, requiresPrivilegedHelper: false)
        let outcomes = RemovalExecutor.execute([item])

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
        let outcomes = RemovalExecutor.execute(plan)

        #expect(outcomes.filter(\.succeeded).count == 1)
        #expect(!FileManager.default.fileExists(atPath: ownedFile.path))
        #expect(FileManager.default.fileExists(atPath: sharedFile.path))
    }
}
