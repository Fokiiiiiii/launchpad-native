import Foundation
import Testing
@testable import Persistence

@Test func saveThenLoadRoundTrips() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)

    var doc = LayoutDocument.empty
    doc.lastSelectedPage = 3
    doc.aliases[StableAppIdentifier(value: "abc")] = "My Alias"

    try await store.save(doc)
    let loaded = await store.load()

    #expect(loaded.lastSelectedPage == 3)
    #expect(loaded.aliases[StableAppIdentifier(value: "abc")] == "My Alias")
}

@Test func loadFallsBackToLastKnownGoodWhenPrimaryIsCorrupted() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)

    var doc = LayoutDocument.empty
    doc.lastSelectedPage = 7
    // Save twice so the backup slot (only populated on the *second+* save,
    // once a previous primary exists to promote) actually holds this state.
    try await store.save(doc)
    try await store.save(doc)

    // Corrupt the primary file directly, simulating a torn/partial write.
    try Data("not valid json".utf8).write(to: dir.appendingPathComponent("layout.json"))

    let loaded = await store.load()
    #expect(loaded.lastSelectedPage == 7)
}

@Test func loadReturnsEmptyWhenNothingExistsYet() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)

    let loaded = await store.load()
    #expect(loaded.schemaVersion == LayoutDocument.currentSchemaVersion)
    #expect(loaded.pages == [[]])
}

@Test func secondSaveDoesNotLoseDataIfInterrupted() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)

    var first = LayoutDocument.empty
    first.lastSelectedPage = 1
    try await store.save(first)

    var second = LayoutDocument.empty
    second.lastSelectedPage = 2
    try await store.save(second)

    // The backup should hold the previous good state after two saves.
    let backupData = try Data(contentsOf: dir.appendingPathComponent("layout.lastknowngood.json"))
    let backupDoc = try JSONDecoder().decode(LayoutDocument.self, from: backupData)
    #expect(backupDoc.lastSelectedPage == 1)
}
