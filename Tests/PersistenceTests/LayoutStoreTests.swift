import Foundation
import Testing
@testable import Persistence

@Test func saveThenLoadRoundTrips() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)

    var doc = LayoutDocument.empty
    doc.gridSettings.columns = 3
    doc.aliases[StableAppIdentifier(value: "abc")] = "My Alias"

    try await store.save(doc)
    let loaded = await store.load()

    #expect(loaded.gridSettings.columns == 3)
    #expect(loaded.aliases[StableAppIdentifier(value: "abc")] == "My Alias")
}

@Test func dateAddedAndLastUsedRoundTrip() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)

    var doc = LayoutDocument.empty
    let added = Date(timeIntervalSince1970: 1_700_000_000)
    let used = Date(timeIntervalSince1970: 1_750_000_000)
    doc.dateAddedByID[StableAppIdentifier(value: "abc")] = added
    doc.lastUsedByID[StableAppIdentifier(value: "abc")] = used

    try await store.save(doc)
    let loaded = await store.load()

    #expect(loaded.dateAddedByID[StableAppIdentifier(value: "abc")] == added)
    #expect(loaded.lastUsedByID[StableAppIdentifier(value: "abc")] == used)
}

@Test func round20SettingsFieldsRoundTrip() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)

    var doc = LayoutDocument.empty
    doc.showsMenuBarIcon = false
    doc.showsHiddenAppsInSearch = true
    doc.backgroundMode = .wallpaper
    doc.glassMaterialIntensity = 0.62
    doc.blursWallpaper = false

    try await store.save(doc)
    let loaded = await store.load()

    #expect(loaded.showsMenuBarIcon == false)
    #expect(loaded.showsHiddenAppsInSearch == true)
    #expect(loaded.backgroundMode == .wallpaper)
    #expect(loaded.glassMaterialIntensity == 0.62)
    #expect(loaded.blursWallpaper == false)
}

/// Same regression class as `decodingADocumentSavedBeforeNewerFieldsExistedUsesSensibleDefaults`
/// below, for the 5 fields Round 20 added.
@Test func decodingADocumentSavedBeforeRound20FieldsExistedUsesSensibleDefaults() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    var doc = LayoutDocument.empty
    doc.gridSettings.columns = 9
    let encoded = try JSONEncoder().encode(doc)

    var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    json.removeValue(forKey: "showsMenuBarIcon")
    json.removeValue(forKey: "showsHiddenAppsInSearch")
    json.removeValue(forKey: "backgroundMode")
    json.removeValue(forKey: "glassMaterialIntensity")
    json.removeValue(forKey: "blursWallpaper")
    let oldSchemaData = try JSONSerialization.data(withJSONObject: json)

    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try oldSchemaData.write(to: dir.appendingPathComponent("layout.json"))

    let store = LayoutStore(directory: dir)
    let loaded = await store.load()

    #expect(loaded.gridSettings.columns == 9) // proves the file actually decoded, not a fallback to .empty
    #expect(loaded.showsMenuBarIcon == true)
    #expect(loaded.showsHiddenAppsInSearch == false)
    #expect(loaded.backgroundMode == .glass)
    #expect(loaded.glassMaterialIntensity == 0.35)
    #expect(loaded.blursWallpaper == true)
}

@Test func loadFallsBackToLastKnownGoodWhenPrimaryIsCorrupted() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)

    var doc = LayoutDocument.empty
    doc.gridSettings.columns = 7
    // Save twice so the backup slot (only populated on the *second+* save,
    // once a previous primary exists to promote) actually holds this state.
    try await store.save(doc)
    try await store.save(doc)

    // Corrupt the primary file directly, simulating a torn/partial write.
    try Data("not valid json".utf8).write(to: dir.appendingPathComponent("layout.json"))

    let loaded = await store.load()
    #expect(loaded.gridSettings.columns == 7)
}

@Test func loadReturnsEmptyWhenNothingExistsYet() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)

    let loaded = await store.load()
    #expect(loaded.schemaVersion == LayoutDocument.currentSchemaVersion)
    #expect(loaded.pages == [[]])
}

/// Regression test for a real, confirmed risk: `sortMode`, `hideDockWhileLauncherOpen`,
/// and `multitouchFingerCount` were all added to their structs after real
/// `layout.json` files already existed on disk. A synthesized `Decodable`
/// requires every key present, so decoding an old file missing any of
/// these would fail the whole `LayoutDocument`, which `LayoutStore.load()`
/// then falls back past the last-known-good backup (usually the same old
/// schema) straight to `.empty` — silently wiping the user's real grid.
/// All three now decode leniently (`decodeIfPresent(...) ?? default`) for
/// exactly this reason; this test simulates a pre-these-fields file by
/// encoding a real document and stripping the new keys back out.
@Test func decodingADocumentSavedBeforeNewerFieldsExistedUsesSensibleDefaults() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    var doc = LayoutDocument.empty
    doc.gridSettings.columns = 5
    let encoded = try JSONEncoder().encode(doc)

    var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    json.removeValue(forKey: "hideDockWhileLauncherOpen")
    json.removeValue(forKey: "dateAddedByID")
    json.removeValue(forKey: "lastUsedByID")
    json.removeValue(forKey: "showMenuBarApplications")
    json.removeValue(forKey: "menuIconVisibility")
    var gridSettings = json["gridSettings"] as! [String: Any]
    gridSettings.removeValue(forKey: "sortMode")
    gridSettings.removeValue(forKey: "iconScale")
    json["gridSettings"] = gridSettings
    var triggerSettings = json["triggerSettings"] as! [String: Any]
    triggerSettings.removeValue(forKey: "multitouchFingerCount")
    triggerSettings.removeValue(forKey: "gestureConflictPreventionEnabled")
    triggerSettings.removeValue(forKey: "gestureConflictBackup")
    json["triggerSettings"] = triggerSettings
    let oldSchemaData = try JSONSerialization.data(withJSONObject: json)

    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try oldSchemaData.write(to: dir.appendingPathComponent("layout.json"))

    let store = LayoutStore(directory: dir)
    let loaded = await store.load()

    #expect(loaded.gridSettings.columns == 5) // proves the file actually decoded, not a fallback to .empty
    #expect(loaded.hideDockWhileLauncherOpen == false)
    #expect(loaded.showMenuBarApplications == true)
    #expect(loaded.gridSettings.sortMode == .custom)
    #expect(loaded.gridSettings.iconScale == 1.05)
    #expect(loaded.triggerSettings.multitouchFingerCount == 4)
    #expect(loaded.triggerSettings.gestureConflictPreventionEnabled == false)
    #expect(loaded.triggerSettings.gestureConflictBackup == nil)
    #expect(loaded.dateAddedByID.isEmpty)
    #expect(loaded.lastUsedByID.isEmpty)
    #expect(loaded.menuIconVisibility == .automatic)
}

@Test func secondSaveDoesNotLoseDataIfInterrupted() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)

    var first = LayoutDocument.empty
    first.gridSettings.columns = 1
    try await store.save(first)

    var second = LayoutDocument.empty
    second.gridSettings.columns = 2
    try await store.save(second)

    // The backup should hold the previous good state after two saves.
    let backupData = try Data(contentsOf: dir.appendingPathComponent("layout.lastknowngood.json"))
    let backupDoc = try JSONDecoder().decode(LayoutDocument.self, from: backupData)
    #expect(backupDoc.gridSettings.columns == 1)
}

@Test func saveReportsDirectoryCreationFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blocker = root.appendingPathComponent("not-a-directory")
    try Data("blocker".utf8).write(to: blocker)

    let store = LayoutStore(directory: blocker)
    var didFailWithDirectoryError = false
    do {
        try await store.save(.empty)
    } catch LayoutStoreError.directoryCreationFailed(_) {
        didFailWithDirectoryError = true
    } catch {
        #expect(Bool(false), "unexpected error: \(error)")
    }

    #expect(didFailWithDirectoryError)
}

@Test func backupPreparationFailureDoesNotReplacePrimary() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)

    var first = LayoutDocument.empty
    first.gridSettings.columns = 1
    try await store.save(first)

    // Removing write permission from the parent makes creation of the
    // temporary backup fail before the old primary can be replaced.
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: dir.path) }

    var second = LayoutDocument.empty
    second.gridSettings.columns = 2
    var didFailWithBackupError = false
    do {
        try await store.save(second)
    } catch LayoutStoreError.backupFailed(_) {
        didFailWithBackupError = true
    } catch {
        #expect(Bool(false), "unexpected error: \(error)")
    }

    #expect(didFailWithBackupError)
    #expect((await store.load()).gridSettings.columns == 1)
}
