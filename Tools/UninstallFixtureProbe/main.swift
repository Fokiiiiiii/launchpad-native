// Phase 8 manual verification: runs the real ownership evidence collector
// and removal planner against the fixture built by
// Scripts/build-uninstall-fixture.sh — proves the filesystem-reading code
// works against real files without ever touching a real installed app.
import Catalog
import Foundation
import Uninstall

let bundleID = "com.launchpadnative.uninstallfixture"
let siblingBundleID = "com.launchpadnative.uninstallfixture.helpertool"
let fixtureApp = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".cache/launchpad-native/fixtures/UninstallFixture.app")

// A fabricated team identifier: this fixture bundle is never actually code
// signed, but two *real* sibling apps sharing a paid Developer ID would have
// a real matching `teamIdentifier` — supplying one here exercises the exact
// sharedRisk path that real classification would take.
let fixtureTeamID = "FIXTURETEAM1"

let mainRecord = ApplicationRecord(
    id: StableAppID(bundleURL: fixtureApp, bundleIdentifier: bundleID, teamIdentifier: fixtureTeamID),
    bundleIdentifier: bundleID,
    bundleURL: fixtureApp,
    executableURL: fixtureApp.appendingPathComponent("Contents/MacOS/UninstallFixture"),
    displayName: "UninstallFixture",
    originalDisplayName: "UninstallFixture",
    bundleVersion: "1.0",
    teamIdentifier: fixtureTeamID,
    category: nil,
    sourceID: "fixture",
    isSystemProtected: false,
    isBackgroundOnly: false,
    iconCacheKey: bundleID,
    canLaunch: false,
    canOpenNewInstance: false,
    lastSeenModificationDate: Date()
)

let siblingRecord = ApplicationRecord(
    id: StableAppID(bundleURL: fixtureApp, bundleIdentifier: siblingBundleID, teamIdentifier: fixtureTeamID),
    bundleIdentifier: siblingBundleID,
    bundleURL: fixtureApp,
    executableURL: nil,
    displayName: "UninstallFixture Helper",
    originalDisplayName: "UninstallFixture Helper",
    bundleVersion: "1.0",
    teamIdentifier: fixtureTeamID,
    category: nil,
    sourceID: "fixture",
    isSystemProtected: false,
    isBackgroundOnly: true,
    iconCacheKey: siblingBundleID,
    canLaunch: false,
    canOpenNewInstance: false,
    lastSeenModificationDate: Date()
)

print("Collecting ownership evidence for \(bundleID)...")
let evidence = OwnershipEvidenceCollector.collect(for: mainRecord)
print("Related paths:")
for path in evidence.relatedPaths {
    print("  \(path.category) exists=\(path.exists) \(path.url.path)")
}
print("User LaunchAgents: \(evidence.userLaunchAgents.map(\.path))")
print("System launch items: \(evidence.systemLaunchItems.map(\.path))")
print("Receipt package IDs: \(evidence.receiptPackageIDs)")

let plan = RemovalPlanner.plan(for: mainRecord, evidence: evidence, siblingRecords: [siblingRecord])
print("\nRemoval plan (\(plan.count) items):")
for item in plan {
    print("  [\(item.classification)] privilegedHelper=\(item.requiresPrivilegedHelper) \(item.path.path)")
}

let store = OperationReportStore()
Task {
    do {
        let report = OperationReport(bundleIdentifier: bundleID, generatedAt: Date(), plan: plan)
        let url = try await store.save(report)
        print("\nDry-run report saved: \(url.path)")
    } catch {
        print("\nFailed to save report: \(error)")
    }
    exit(0)
}
RunLoop.main.run(until: Date().addingTimeInterval(5))
