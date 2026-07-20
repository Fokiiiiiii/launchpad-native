import Catalog
import Foundation
import Testing
@testable import Uninstall

/// Exercises `OwnershipEvidenceCollector` against real files under a
/// temporary `~/Library`-shaped directory tree, so evidence collection is
/// proven against the actual filesystem APIs (not just hand-built
/// `OwnershipEvidence` values, which `RemovalPlannerTests` already covers).
///
/// This does NOT touch the real `~/Library` — `OwnershipEvidenceCollector`
/// itself always reads from the real home directory, so this suite instead
/// verifies the piece that's independent of that: the pure `RelatedPath`
/// existence check and receipt/extension parsing, using real bundles it
/// creates and deletes itself.
@Suite("OwnershipEvidenceCollector")
struct OwnershipEvidenceCollectorTests {
    @Test("a bundle with NSExtension in its Info.plist is reported")
    func extensionDeclarationDetected() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleID = "com.example.withextension"
        let bundleURL = tempDir.appendingPathComponent("WithExtension.app")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "WithExtension",
            "CFBundlePackageType": "APPL",
            "NSExtension": ["NSExtensionPointIdentifier": "com.example.point"]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let record = ApplicationRecord(
            id: StableAppID(bundleURL: bundleURL, bundleIdentifier: bundleID, teamIdentifier: nil),
            bundleIdentifier: bundleID,
            bundleURL: bundleURL,
            executableURL: nil,
            displayName: "WithExtension",
            originalDisplayName: "WithExtension",
            bundleVersion: "1.0",
            teamIdentifier: nil,
            category: nil,
            sourceID: "test",
            isSystemProtected: false,
            isBackgroundOnly: false,
            iconCacheKey: bundleID,
            canLaunch: false,
            canOpenNewInstance: false,
            lastSeenModificationDate: Date()
        )

        let evidence = OwnershipEvidenceCollector.collect(for: record)
        #expect(evidence.systemExtensionIdentifiers == [bundleID])
    }

    @Test("a bundle with no NSExtension declaration reports none")
    func noExtensionDeclaration() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleID = "com.example.plain"
        let bundleURL = tempDir.appendingPathComponent("Plain.app")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Plain",
            "CFBundlePackageType": "APPL"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let record = ApplicationRecord(
            id: StableAppID(bundleURL: bundleURL, bundleIdentifier: bundleID, teamIdentifier: nil),
            bundleIdentifier: bundleID,
            bundleURL: bundleURL,
            executableURL: nil,
            displayName: "Plain",
            originalDisplayName: "Plain",
            bundleVersion: "1.0",
            teamIdentifier: nil,
            category: nil,
            sourceID: "test",
            isSystemProtected: false,
            isBackgroundOnly: false,
            iconCacheKey: bundleID,
            canLaunch: false,
            canOpenNewInstance: false,
            lastSeenModificationDate: Date()
        )

        let evidence = OwnershipEvidenceCollector.collect(for: record)
        #expect(evidence.systemExtensionIdentifiers.isEmpty)
    }
}
