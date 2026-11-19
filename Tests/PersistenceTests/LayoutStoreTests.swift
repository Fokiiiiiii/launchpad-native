import Foundation
import Testing
@testable import Persistence

import Darwin

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

@Test func rustLayoutDecoderMatchesLegacyCodable() throws {
    var document = LayoutDocument.empty
    let app = StableAppIdentifier(value: "app-日本")
    let folderID = FolderID(value: "folder-1")
    document.pages = [[.app(app), .folder(folderID)]]
    document.folders[folderID] = Folder(id: folderID, name: "仕事 👨‍👩‍👧", pages: [[.app(StableAppIdentifier(value: "inside"))]])
    document.aliases[app] = "別名\u{0}終"
    document.hiddenApplicationIDs = [StableAppIdentifier(value: "hidden")]
    document.dateAddedByID[app] = Date(timeIntervalSinceReferenceDate: -123.25)
    document.lastUsedByID[app] = Date(timeIntervalSinceReferenceDate: 123456.75)
    document.knownApplications[app] = KnownApplication(bundleIdentifier: "com.example", teamIdentifier: nil)
    document.triggerSettings.gestureConflictBackup = GestureConflictBackup(fingerCount: 4, values: ["absent": nil, "present": 2], valuesByFingerCount: [4: ["a": nil, "b": 1]], launchpadGestureValue: nil, launchpadGestureWasPresent: false, launchpadGestureCaptured: true)
    document.customSources = [CustomSourceConfig(id: "source", rootPath: "/tmp/日本 語", recursive: true, includeGlobs: ["*.app"], excludeGlobs: [], priority: -1, enabled: true)]
    let encoded = try JSONEncoder().encode(document)
    let swift = try JSONDecoder().decode(LayoutDocument.self, from: encoded)
    let rust = try RustLayoutJSON.decode(encoded)
    #expect(rust.pages == swift.pages)
    #expect(rust.folders == swift.folders)
    #expect(rust.aliases == swift.aliases)
    #expect(rust.hiddenApplicationIDs == swift.hiddenApplicationIDs)
    #expect(rust.dateAddedByID == swift.dateAddedByID)
    #expect(rust.lastUsedByID == swift.lastUsedByID)
    #expect(rust.knownApplications == swift.knownApplications)
    #expect(rust.triggerSettings == swift.triggerSettings)
    #expect(rust.customSources == swift.customSources)
    #expect(rust.gridSettings == swift.gridSettings)
    let encodedRust = try RustLayoutJSON.encode(document)
    let swiftObject = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
    let rustObject = try #require(JSONSerialization.jsonObject(with: encodedRust) as? NSDictionary)
    #expect(swiftObject == rustObject)
    let decodedSwift = try JSONDecoder().decode(LayoutDocument.self, from: encodedRust)
    let decodedRust = try RustLayoutJSON.decode(encodedRust)
    #expect(decodedSwift.pages == swift.pages)
    #expect(decodedSwift.folders == swift.folders)
    #expect(decodedSwift.aliases == swift.aliases)
    #expect(decodedSwift.hiddenApplicationIDs == swift.hiddenApplicationIDs)
    #expect(decodedSwift.dateAddedByID == swift.dateAddedByID)
    #expect(decodedSwift.lastUsedByID == swift.lastUsedByID)
    #expect(decodedSwift.knownApplications == swift.knownApplications)
    #expect(decodedSwift.triggerSettings == swift.triggerSettings)
    #expect(decodedSwift.customSources == swift.customSources)
    #expect(decodedRust.triggerSettings == swift.triggerSettings)
    #expect(decodedRust.pages == swift.pages)
    #expect(throws: (any Error).self) { try RustLayoutJSON.decode(Data("{\"schemaVersion\":1}".utf8)) }
}

@Test func rustJSONEncoderMatchesFoundationForDataAndDates() throws {
    struct Fixture: Encodable {
        let payload: Data
        let list: [Data]
        let date: Date
        let url: URL
    }
    let fixture = Fixture(payload: Data([0, 255, 1]), list: [Data(), Data([42])], date: Date(timeIntervalSinceReferenceDate: 42.5), url: URL(fileURLWithPath: "/tmp/日本 語"))
    let expected = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? NSDictionary)
    let actual = try #require(JSONSerialization.jsonObject(with: RustJSONCodec.encode(fixture)) as? NSDictionary)
    #expect(actual == expected)
}

@Test func rustLayoutCodecHandlesIntegerLimitsAndOptionalNulls() throws {
    for index in 0..<30 {
        var document = LayoutDocument.empty
        document.gridSettings.columns = 1 + index % 12
        document.gridSettings.rows = 1 + index % 8
        document.triggerSettings.hotkeyModifierFlags = index.isMultiple(of: 2) ? UInt.max : UInt(index)
        document.triggerSettings.hotkeyKeyCode = index.isMultiple(of: 2) ? UInt16.max : nil
        document.triggerSettings.gestureConflictBackup = GestureConflictBackup(fingerCount: 4, values: ["nil": nil, "number": index], valuesByFingerCount: [4: ["x": nil]], launchpadGestureValue: index.isMultiple(of: 2) ? index : nil, launchpadGestureWasPresent: index.isMultiple(of: 2), launchpadGestureCaptured: true)
        let id = StableAppIdentifier(value: "日本-\(index)")
        document.pages = [[.app(id)]]
        document.aliases[id] = "名\(index)"
        document.dateAddedByID[id] = Date(timeIntervalSinceReferenceDate: Double(index) - 100.25)
        let swiftData = try JSONEncoder().encode(document)
        let rustData = try RustLayoutJSON.encode(document)
        let fromSwift = try RustLayoutJSON.decode(swiftData)
        let fromRust = try JSONDecoder().decode(LayoutDocument.self, from: rustData)
        #expect(fromSwift.triggerSettings == document.triggerSettings)
        #expect(fromRust.triggerSettings == document.triggerSettings)
        #expect(fromSwift.pages == document.pages)
        #expect(fromRust.pages == document.pages)
        #expect(fromSwift.aliases == document.aliases)
        #expect(fromRust.dateAddedByID == document.dateAddedByID)
    }
}

@Test func rustLayoutDecoderHandlesLegacyUnicodeEncodingsAndDuplicateKeys() throws {
    var document = LayoutDocument.empty
    document.aliases[StableAppIdentifier(value: "日本")] = "名前"
    let encoded = try JSONEncoder().encode(document)
    let text = try #require(String(data: encoded, encoding: .utf8))
    for encoding: String.Encoding in [.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
        let bytes = try #require(text.data(using: encoding))
        let expected = try JSONDecoder().decode(LayoutDocument.self, from: bytes)
        let actual = try RustLayoutJSON.decode(bytes)
        #expect(actual.aliases == expected.aliases)
        #expect(actual.gridSettings == expected.gridSettings)
    }
    let duplicate = Data(("{\"schemaVersion\":2," + text.dropFirst()).utf8)
    let expected = try JSONDecoder().decode(LayoutDocument.self, from: duplicate)
    let actual = try RustLayoutJSON.decode(duplicate)
    #expect(expected.schemaVersion == 2)
    #expect(actual.schemaVersion == expected.schemaVersion)
}

@Test func rustLayoutCodecPreservesLargePageAndAliasArrays() throws {
    var document = LayoutDocument.empty
    let items = (0..<10_000).map { StableAppIdentifier(value: "app-\($0)") }
    document.pages = stride(from: 0, to: items.count, by: 35).map { start in
        Array(items[start..<min(start + 35, items.count)]).map(LayoutItem.app)
    }
    for item in items { document.aliases[item] = "別名 \(item.value)" }
    let legacy = try JSONEncoder().encode(document)
    let decoded = try RustLayoutJSON.decode(legacy)
    #expect(decoded.pages == document.pages)
    #expect(decoded.aliases == document.aliases)
    let encoded = try RustLayoutJSON.encode(document)
    let restored = try JSONDecoder().decode(LayoutDocument.self, from: encoded)
    #expect(restored.pages == document.pages)
    #expect(restored.aliases == document.aliases)
}

@Test func benchmarkLayoutJSON() throws {
    guard ProcessInfo.processInfo.environment["LAUNCHPAD_BENCHMARK"] == "1" else { return }
    var document = LayoutDocument.empty
    let items = (0..<1000).map { StableAppIdentifier(value: "app-\($0)") }
    document.pages = stride(from: 0, to: items.count, by: 35).map { start in
        Array(items[start..<min(start + 35, items.count)]).map(LayoutItem.app)
    }
    for item in items { document.aliases[item] = "アプリ \(item.value)" }
    var swiftData = Data()
    let swiftEncodeStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<10 { swiftData = try JSONEncoder().encode(document) }
    let swiftEncode = DispatchTime.now().uptimeNanoseconds - swiftEncodeStart
    var rustData = Data()
    let rustEncodeStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<10 { rustData = try RustLayoutJSON.encode(document) }
    let rustEncode = DispatchTime.now().uptimeNanoseconds - rustEncodeStart
    let swiftDecodeStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<10 { #expect(try JSONDecoder().decode(LayoutDocument.self, from: swiftData).pages.count == document.pages.count) }
    let swiftDecode = DispatchTime.now().uptimeNanoseconds - swiftDecodeStart
    let rustDecodeStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<10 { #expect(try RustLayoutJSON.decode(rustData).pages.count == document.pages.count) }
    let rustDecode = DispatchTime.now().uptimeNanoseconds - rustDecodeStart
    print("LAYOUT_JSON_BENCH items=1000 rounds=10 swift_encode_ns=\(swiftEncode) rust_encode_ns=\(rustEncode) swift_decode_ns=\(swiftDecode) rust_decode_ns=\(rustDecode)")
}

@Test func benchmarkLayoutMemory() throws {
    guard ProcessInfo.processInfo.environment["LAUNCHPAD_BENCHMARK"] == "1",
          let mode = ProcessInfo.processInfo.environment["LAUNCHPAD_MEMORY_MODE"] else { return }
    let count = Int(ProcessInfo.processInfo.environment["LAUNCHPAD_MEMORY_ITEMS"] ?? "1000") ?? 1000
    guard (1...10_000).contains(count) else { return }
    var document = LayoutDocument.empty
    let items = (0..<count).map { StableAppIdentifier(value: "app-\($0)") }
    document.pages = stride(from: 0, to: items.count, by: 35).map { start in
        Array(items[start..<min(start + 35, items.count)]).map(LayoutItem.app)
    }
    for item in items { document.aliases[item] = "アプリ \(item.value)" }
    let input = mode.hasPrefix("decode") ? try JSONEncoder().encode(document) : Data()
    func peak() -> Int {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        return usage.ru_maxrss
    }
    let baseline = peak()
    var checksum = 0
    for _ in 0..<5 {
        switch mode {
        case "encode-swift": checksum += try JSONEncoder().encode(document).count
        case "encode-rust": checksum += try RustLayoutJSON.encode(document).count
        case "decode-swift": checksum += try JSONDecoder().decode(LayoutDocument.self, from: input).pages.count
        case "decode-rust": checksum += try RustLayoutJSON.decode(input).pages.count
        default: return
        }
    }
    #expect(checksum > 0)
    print("MEMORY_BENCH scenario=layout mode=\(mode) items=\(count) baseline_bytes=\(baseline) peak_bytes=\(peak())")
}

/// After `load()` fell back to the backup, the damaged primary was copied over
/// that backup on the next save — so a failure while writing the new file left
/// nothing readable at all.
@Test func aDamagedPrimaryIsSetAsideInsteadOfReplacingTheGoodBackup() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)

    var first = LayoutDocument.empty
    first.gridSettings.columns = 5
    try await store.save(first)
    var second = LayoutDocument.empty
    second.gridSettings.columns = 6
    try await store.save(second)

    try Data("not json".utf8).write(to: dir.appendingPathComponent("layout.json"))
    #expect(await store.load().gridSettings.columns == 5)

    var third = LayoutDocument.empty
    third.gridSettings.columns = 7
    try await store.save(third)

    let backup = try JSONDecoder().decode(
        LayoutDocument.self,
        from: Data(contentsOf: dir.appendingPathComponent("layout.lastknowngood.json"))
    )
    #expect(backup.gridSettings.columns == 5, "the good backup was replaced by the damaged file")
    #expect(await store.load().gridSettings.columns == 7)

    let setAside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasPrefix("layout.unreadable-") }
    #expect(setAside.count == 1)
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
    json.removeValue(forKey: "wallpaperBlurRadius")
    json.removeValue(forKey: "returnToFirstPage")
    json.removeValue(forKey: "closeOnBackgroundClick")
    json.removeValue(forKey: "screenTarget")
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
    #expect(loaded.wallpaperBlurRadius == 8)
    #expect(loaded.returnToFirstPage == false)
    #expect(loaded.closeOnBackgroundClick == true)
    #expect(loaded.screenTarget == .cursor)
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

    try Data().write(to: dir.appendingPathComponent("layout.json"))
    #expect(await store.load().gridSettings.columns == 7)
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

@Test func exportingBackupCannotOverwriteLiveLayout() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)
    var document = LayoutDocument.empty
    document.gridSettings.columns = 9
    try await store.save(document)
    let primary = dir.appendingPathComponent("layout.json")
    do {
        try await store.writeBackup(Data("not a layout".utf8), to: primary)
        Issue.record("the live layout was overwritten")
    } catch {
        #expect((await store.load()).gridSettings.columns == 9)
    }
}
