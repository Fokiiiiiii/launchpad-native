import Catalog
import Foundation
import Testing
@testable import Uninstall

private func makeRecord(
    bundleIdentifier: String,
    teamIdentifier: String?,
    isSystemProtected: Bool = false
) -> ApplicationRecord {
    let bundleURL = URL(fileURLWithPath: "/tmp/\(bundleIdentifier).app")
    return ApplicationRecord(
        id: StableAppID(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier),
        bundleIdentifier: bundleIdentifier,
        bundleURL: bundleURL,
        executableURL: nil,
        displayName: bundleIdentifier,
        originalDisplayName: bundleIdentifier,
        bundleVersion: "1.0",
        teamIdentifier: teamIdentifier,
        category: nil,
        sourceID: "test",
        isSystemProtected: isSystemProtected,
        isBackgroundOnly: false,
        iconCacheKey: bundleIdentifier,
        canLaunch: true,
        canOpenNewInstance: false,
        lastSeenModificationDate: Date()
    )
}

@Suite("RemovalPlanner")
struct RemovalPlannerTests {
    @Test("system-protected apps collapse to a single unknown item")
    func systemProtectedRejectsPlan() {
        let record = makeRecord(bundleIdentifier: "com.apple.finder", teamIdentifier: nil, isSystemProtected: true)
        let evidence = OwnershipEvidence(
            bundleURL: record.bundleURL,
            relatedPaths: [RelatedPath(url: URL(fileURLWithPath: "/tmp/whatever"), category: .applicationSupport, exists: true)],
            userLaunchAgents: [],
            systemLaunchItems: [],
            receiptPackageIDs: [],
            systemExtensionIdentifiers: []
        )
        let plan = RemovalPlanner.plan(for: record, evidence: evidence)
        #expect(plan.count == 1)
        #expect(plan[0].classification == .unknown)
        #expect(plan[0].path == record.bundleURL)
    }

    @Test("a related path with no code-signing team is owned")
    func ownedWhenNoTeamIdentifier() {
        let record = makeRecord(bundleIdentifier: "com.example.solo", teamIdentifier: nil)
        let path = URL(fileURLWithPath: "/tmp/com.example.solo")
        let evidence = OwnershipEvidence(
            bundleURL: record.bundleURL,
            relatedPaths: [RelatedPath(url: path, category: .applicationSupport, exists: true)],
            userLaunchAgents: [],
            systemLaunchItems: [],
            receiptPackageIDs: [],
            systemExtensionIdentifiers: []
        )
        let plan = RemovalPlanner.plan(for: record, evidence: evidence)
        #expect(plan.count == 1)
        #expect(plan[0].classification == .owned)
        #expect(plan[0].requiresPrivilegedHelper == false)
    }

    @Test("a related path nested with a same-team sibling's data is sharedRisk")
    func sharedRiskWhenSiblingDataNested() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let record = makeRecord(bundleIdentifier: "com.example.main", teamIdentifier: "TEAM123")
        let sibling = makeRecord(bundleIdentifier: "com.example.helper", teamIdentifier: "TEAM123")

        let ownedPath = tempDir.appendingPathComponent("com.example.main")
        let nestedSiblingPath = ownedPath.appendingPathComponent(sibling.bundleIdentifier)
        try FileManager.default.createDirectory(at: nestedSiblingPath, withIntermediateDirectories: true)

        let evidence = OwnershipEvidence(
            bundleURL: record.bundleURL,
            relatedPaths: [RelatedPath(url: ownedPath, category: .applicationSupport, exists: true)],
            userLaunchAgents: [],
            systemLaunchItems: [],
            receiptPackageIDs: [],
            systemExtensionIdentifiers: []
        )
        let plan = RemovalPlanner.plan(for: record, evidence: evidence, siblingRecords: [sibling])
        #expect(plan.count == 1)
        #expect(plan[0].classification == .sharedRisk)
    }

    @Test("a same-team sibling with no nested data does not force sharedRisk")
    func ownedWhenSiblingSharesTeamButNoNesting() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let record = makeRecord(bundleIdentifier: "com.example.main", teamIdentifier: "TEAM123")
        let sibling = makeRecord(bundleIdentifier: "com.example.unrelated", teamIdentifier: "TEAM123")
        let ownedPath = tempDir.appendingPathComponent("com.example.main")
        try FileManager.default.createDirectory(at: ownedPath, withIntermediateDirectories: true)

        let evidence = OwnershipEvidence(
            bundleURL: record.bundleURL,
            relatedPaths: [RelatedPath(url: ownedPath, category: .applicationSupport, exists: true)],
            userLaunchAgents: [],
            systemLaunchItems: [],
            receiptPackageIDs: [],
            systemExtensionIdentifiers: []
        )
        let plan = RemovalPlanner.plan(for: record, evidence: evidence, siblingRecords: [sibling])
        #expect(plan.count == 1)
        #expect(plan[0].classification == .owned)
    }

    @Test("user LaunchAgents are owned and don't require a privileged helper")
    func userLaunchAgentIsOwned() {
        let record = makeRecord(bundleIdentifier: "com.example.solo", teamIdentifier: nil)
        let agentURL = URL(fileURLWithPath: "/tmp/com.example.solo.helper.plist")
        let evidence = OwnershipEvidence(
            bundleURL: record.bundleURL,
            relatedPaths: [],
            userLaunchAgents: [agentURL],
            systemLaunchItems: [],
            receiptPackageIDs: [],
            systemExtensionIdentifiers: []
        )
        let plan = RemovalPlanner.plan(for: record, evidence: evidence)
        #expect(plan.count == 1)
        #expect(plan[0].classification == .owned)
        #expect(plan[0].requiresPrivilegedHelper == false)
    }

    @Test("system-domain launch items are sharedRisk and require a privileged helper")
    func systemLaunchItemRequiresPrivilegedHelper() {
        let record = makeRecord(bundleIdentifier: "com.example.solo", teamIdentifier: nil)
        let daemonURL = URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.solo.helper.plist")
        let evidence = OwnershipEvidence(
            bundleURL: record.bundleURL,
            relatedPaths: [],
            userLaunchAgents: [],
            systemLaunchItems: [daemonURL],
            receiptPackageIDs: [],
            systemExtensionIdentifiers: []
        )
        let plan = RemovalPlanner.plan(for: record, evidence: evidence)
        #expect(plan.count == 1)
        #expect(plan[0].classification == .sharedRisk)
        #expect(plan[0].requiresPrivilegedHelper == true)
    }

    @Test("package receipts are unknown and require a privileged helper")
    func receiptsAreUnknownAndRequirePrivilegedHelper() {
        let record = makeRecord(bundleIdentifier: "com.example.solo", teamIdentifier: nil)
        let evidence = OwnershipEvidence(
            bundleURL: record.bundleURL,
            relatedPaths: [],
            userLaunchAgents: [],
            systemLaunchItems: [],
            receiptPackageIDs: ["com.example.solo.pkg"],
            systemExtensionIdentifiers: []
        )
        let plan = RemovalPlanner.plan(for: record, evidence: evidence)
        #expect(plan.count == 1)
        #expect(plan[0].classification == .unknown)
        #expect(plan[0].requiresPrivilegedHelper == true)
    }

    @Test("a Group Container is always sharedRisk, even with no team-sharing sibling installed")
    func groupContainerIsAlwaysSharedRisk() {
        // No teamIdentifier at all, and no siblingRecords — the ordinary
        // classify() rule would call this `.owned` (nothing to compare
        // against), but Group Containers are shared by design and must
        // never be treated as safely owned regardless.
        let record = makeRecord(bundleIdentifier: "com.example.solo", teamIdentifier: nil)
        let groupPath = URL(fileURLWithPath: "/tmp/group.com.example.solo")
        let evidence = OwnershipEvidence(
            bundleURL: record.bundleURL,
            relatedPaths: [RelatedPath(url: groupPath, category: .groupContainers, exists: true)],
            userLaunchAgents: [],
            systemLaunchItems: [],
            receiptPackageIDs: [],
            systemExtensionIdentifiers: []
        )
        let plan = RemovalPlanner.plan(for: record, evidence: evidence)
        #expect(plan.count == 1)
        #expect(plan[0].classification == .sharedRisk)
    }

    @Test("nonexistent related paths are excluded from the plan")
    func nonexistentPathsExcluded() {
        let record = makeRecord(bundleIdentifier: "com.example.solo", teamIdentifier: nil)
        let evidence = OwnershipEvidence(
            bundleURL: record.bundleURL,
            relatedPaths: [RelatedPath(url: URL(fileURLWithPath: "/tmp/missing"), category: .preferences, exists: false)],
            userLaunchAgents: [],
            systemLaunchItems: [],
            receiptPackageIDs: [],
            systemExtensionIdentifiers: []
        )
        let plan = RemovalPlanner.plan(for: record, evidence: evidence)
        #expect(plan.isEmpty)
    }
}
