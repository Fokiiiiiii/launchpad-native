import Catalog
import Foundation
import Persistence
import SQLite3
import Testing
@testable import Grid

private func record(_ name: String, id: String) -> ApplicationRecord {
    ApplicationRecord(
        id: StableAppID(bundleURL: URL(fileURLWithPath: "/tmp/\(name).app"), bundleIdentifier: id, teamIdentifier: nil),
        bundleIdentifier: id,
        bundleURL: URL(fileURLWithPath: "/tmp/\(name).app"),
        executableURL: nil,
        displayName: name,
        originalDisplayName: name,
        bundleVersion: nil,
        teamIdentifier: nil,
        category: nil,
        sourceID: "test",
        isSystemProtected: false,
        isBackgroundOnly: false,
        iconCacheKey: id,
        canLaunch: true,
        canOpenNewInstance: true,
        lastSeenModificationDate: Date(timeIntervalSince1970: 0)
    )
}

/// Builds a tiny fixture Launchpad DB matching the real schema
/// (`ReverseEngineering/Contracts/open-items.md`): root -> holding page ->
/// [one bare app, one folder with two apps].
private func makeFixtureDatabase(at url: URL) throws {
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }

    let statements = [
        "CREATE TABLE items (rowid INTEGER PRIMARY KEY, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER, ordering INTEGER)",
        "CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, storeid VARCHAR, category_id INTEGER, moddate REAL, bookmark BLOB)",
        "CREATE TABLE groups (item_id INTEGER PRIMARY KEY, category_id INTEGER, title VARCHAR)",
        "INSERT INTO items (rowid, uuid, flags, type, parent_id, ordering) VALUES (1, 'ROOTPAGE', 1, 1, 0, 0)",
        "INSERT INTO items (rowid, uuid, flags, type, parent_id, ordering) VALUES (2, 'HOLDINGPAGE', 0, 3, 1, 0)",
        // A bare app directly on the page.
        "INSERT INTO items (rowid, uuid, flags, type, parent_id, ordering) VALUES (10, 'app-a', 0, 4, 2, 0)",
        "INSERT INTO apps (item_id, title, bundleid) VALUES (10, 'AppA', 'com.example.a')",
        // A folder containing two apps.
        "INSERT INTO items (rowid, uuid, flags, type, parent_id, ordering) VALUES (20, 'folder-1', 0, 5, 2, 1)",
        "INSERT INTO groups (item_id, category_id, title) VALUES (20, 0, 'Utilities')",
        "INSERT INTO items (rowid, uuid, flags, type, parent_id, ordering) VALUES (21, 'app-b', 0, 4, 20, 0)",
        "INSERT INTO apps (item_id, title, bundleid) VALUES (21, 'AppB', 'com.example.b')",
        "INSERT INTO items (rowid, uuid, flags, type, parent_id, ordering) VALUES (22, 'app-missing', 0, 4, 20, 1)",
        "INSERT INTO apps (item_id, title, bundleid) VALUES (22, 'AppMissing', 'com.example.missing')"
    ]
    for sql in statements {
        var errMsg: UnsafeMutablePointer<CChar>?
        #expect(sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK)
    }
}

@Test func importReconstructsFoldersAndOrderMatchingByBundleID() throws {
    let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db")
    defer { try? FileManager.default.removeItem(at: dbURL) }
    try makeFixtureDatabase(at: dbURL)

    let records = [record("AppA", id: "com.example.a"), record("AppB", id: "com.example.b")]
    let result = LegacyLaunchpadImporter.importLegacyLayout(from: dbURL, matching: records)

    #expect(result.folders.count == 1)
    #expect(result.folders.first?.name == "Utilities")
    #expect(result.folders.first?.pages.first?.count == 1) // only AppB resolved; AppMissing unresolved

    #expect(result.unresolvedBundleIDs == ["com.example.missing"])

    // unplacedAppOrder should contain: bare app A, then the folder placeholder.
    #expect(result.unplacedAppOrder.count == 2)
    guard case .app(let firstID) = result.unplacedAppOrder[0] else {
        Issue.record("expected first item to be an app")
        return
    }
    #expect(firstID.value == records[0].id.value)
    guard case .folder = result.unplacedAppOrder[1] else {
        Issue.record("expected second item to be a folder")
        return
    }
}

@Test func importReturnsEmptyResultForMissingRoot() throws {
    let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db")
    defer { try? FileManager.default.removeItem(at: dbURL) }
    var db: OpaquePointer?
    #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
    sqlite3_exec(db, "CREATE TABLE items (rowid INTEGER PRIMARY KEY, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER, ordering INTEGER)", nil, nil, nil)
    sqlite3_exec(db, "CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, storeid VARCHAR, category_id INTEGER, moddate REAL, bookmark BLOB)", nil, nil, nil)
    sqlite3_exec(db, "CREATE TABLE groups (item_id INTEGER PRIMARY KEY, category_id INTEGER, title VARCHAR)", nil, nil, nil)
    sqlite3_close(db)

    let result = LegacyLaunchpadImporter.importLegacyLayout(from: dbURL, matching: [])
    #expect(result.folders.isEmpty)
    #expect(result.unplacedAppOrder.isEmpty)
}
