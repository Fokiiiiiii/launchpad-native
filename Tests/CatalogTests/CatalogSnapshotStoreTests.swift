import Foundation
import Testing
@testable import Catalog

private func makeSnapshotFixture(in root: URL, name: String = "Fixture.app") throws -> (ApplicationRecord, ApplicationSource) {
    let bundleURL = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    let modificationDate = (try FileManager.default.attributesOfItem(atPath: bundleURL.path)[.modificationDate] as? Date) ?? Date()
    let bundleID = "com.example.\(name.replacingOccurrences(of: ".app", with: "").lowercased())"
    let record = ApplicationRecord(
        id: StableAppID(bundleURL: bundleURL, bundleIdentifier: bundleID, teamIdentifier: nil),
        bundleIdentifier: bundleID,
        bundleURL: bundleURL,
        executableURL: nil,
        displayName: name,
        originalDisplayName: name,
        bundleVersion: nil,
        teamIdentifier: nil,
        category: nil,
        sourceID: "fixture",
        isSystemProtected: false,
        isBackgroundOnly: false,
        isMenuBarApp: false,
        iconCacheKey: bundleID,
        canLaunch: false,
        canOpenNewInstance: true,
        lastSeenModificationDate: modificationDate
    )
    let source = ApplicationSource(id: "fixture", rootURL: root, recursive: true, priority: 0)
    return (record, source)
}

@Test func catalogSnapshotRoundTripsRecords() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let (record, _) = try makeSnapshotFixture(in: root)
    let data = try CatalogSnapshotStore.encode(records: [record])
    let decoded = try #require(CatalogSnapshotStore.decode(data))
    #expect(decoded == [record])
}

@Test func catalogSnapshotPrunesDeletedBundles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let (record, source) = try makeSnapshotFixture(in: root)
    #expect(CatalogSnapshotStore.prune([record], sources: [source]).count == 1)

    try FileManager.default.removeItem(at: record.bundleURL)
    #expect(CatalogSnapshotStore.prune([record], sources: [source]).isEmpty)
}

@Test func catalogSnapshotEncodingIsBounded() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let (record, _) = try makeSnapshotFixture(in: root)
    let data = try CatalogSnapshotStore.encode(records: Array(repeating: record, count: 4), maximumRecords: 2)
    let decoded = try #require(CatalogSnapshotStore.decode(data, maximumRecords: 2))
    #expect(decoded.count == 2)
}
