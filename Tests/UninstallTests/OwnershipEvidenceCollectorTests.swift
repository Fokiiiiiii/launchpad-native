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

    /// Real files under the real home directory, using a bundle identifier
    /// exclusive to this test run — `OwnershipEvidenceCollector` always
    /// reads the real `~/Library`, so proving the newer categories
    /// (Containers, Group Containers, Saved Application State, WebKit,
    /// HTTPStorages, Cookies, Logs, Application Scripts, ByHost prefs) work
    /// means creating and then cleaning up real files there, same as the
    /// fixture script does for manual verification.
    @Test("newer related-path categories are detected under the real home directory")
    func newerCategoriesDetected() throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bundleID = "com.launchpadnative.uninstalltests.\(UUID().uuidString)"

        let container = home.appendingPathComponent("Library/Containers/\(bundleID)")
        let groupContainer = home.appendingPathComponent("Library/Group Containers/group.\(bundleID)")
        let savedState = home.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState")
        let webKit = home.appendingPathComponent("Library/WebKit/\(bundleID)")
        let httpStorages = home.appendingPathComponent("Library/HTTPStorages/\(bundleID)")
        let cookies = home.appendingPathComponent("Library/Cookies/\(bundleID).binarycookies")
        let logs = home.appendingPathComponent("Library/Logs/\(bundleID)")
        let appScripts = home.appendingPathComponent("Library/Application Scripts/\(bundleID)")
        let byHost = home.appendingPathComponent("Library/Preferences/ByHost/\(bundleID).0123ABCD.plist")

        let directories = [container, groupContainer, savedState, webKit, httpStorages, logs, appScripts]
        for directory in directories {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: cookies)
        try fm.createDirectory(at: byHost.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: byHost)

        defer {
            for directory in directories { try? fm.removeItem(at: directory) }
            try? fm.removeItem(at: cookies)
            try? fm.removeItem(at: byHost)
        }

        let record = ApplicationRecord(
            id: StableAppID(bundleURL: URL(fileURLWithPath: "/tmp/\(bundleID).app"), bundleIdentifier: bundleID, teamIdentifier: nil),
            bundleIdentifier: bundleID,
            bundleURL: URL(fileURLWithPath: "/tmp/\(bundleID).app"),
            executableURL: nil,
            displayName: bundleID,
            originalDisplayName: bundleID,
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
        let categories = Set(evidence.relatedPaths.filter(\.exists).map(\.category))

        #expect(categories.contains(.containers))
        #expect(categories.contains(.groupContainers))
        #expect(categories.contains(.savedApplicationState))
        #expect(categories.contains(.webKit))
        #expect(categories.contains(.httpStorages))
        #expect(categories.contains(.cookies))
        #expect(categories.contains(.logs))
        #expect(categories.contains(.applicationScripts))
        #expect(categories.contains(.preferencesByHost))
    }
}
