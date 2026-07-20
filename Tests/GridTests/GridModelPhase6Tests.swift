import Catalog
import Foundation
import Persistence
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

@MainActor
private func makeModel(directory: URL) -> GridModel {
    GridModel(layoutStore: LayoutStore(directory: directory))
}

@Test @MainActor func hidingAnAppRemovesItFromPagesAndReconcile() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    let apple = record("Apple", id: "a")
    let banana = record("Banana", id: "b")
    model.reconcile(with: [apple, banana])
    #expect(model.pages[0].count == 2)

    model.hideApplication(apple.id)
    #expect(model.pages[0].count == 1)

    // Re-reconciling (e.g. after an FSEvents catalog tick) must not bring it back.
    model.reconcile(with: [apple, banana])
    #expect(model.pages[0].count == 1)
}

@Test @MainActor func unhidingReappendsTheApp() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    let apple = record("Apple", id: "a")
    model.reconcile(with: [apple])
    model.hideApplication(apple.id)
    #expect(model.pages[0].isEmpty)

    model.unhideApplication(apple.id.asPersistenceIdentifier)
    #expect(model.pages[0].count == 1)
    #expect(model.hiddenApplicationIdentifiers.isEmpty)
}

@Test @MainActor func aliasOverridesDisplayNameWithoutTouchingTheRecord() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    let record = record("Terminal", id: "t")
    model.reconcile(with: [record])

    #expect(model.displayName(for: record) == "Terminal")
    model.setAlias("My Shell", for: record.id)
    #expect(model.displayName(for: record) == "My Shell")
    #expect(record.displayName == "Terminal") // untouched

    model.setAlias(nil, for: record.id)
    #expect(model.displayName(for: record) == "Terminal")
}

@Test @MainActor func customSourcesCanBeAddedAndRemoved() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    #expect(model.customSources.isEmpty)
    let config = CustomSourceConfig(id: "s1", rootPath: "/tmp/MyApps", recursive: true, includeGlobs: [], excludeGlobs: [], priority: 30, enabled: true)
    model.addCustomSource(config)
    #expect(model.customSources.count == 1)

    // Adding the same id again is a no-op, not a duplicate.
    model.addCustomSource(config)
    #expect(model.customSources.count == 1)

    model.removeCustomSource(id: "s1")
    #expect(model.customSources.isEmpty)
}

@Test @MainActor func hiddenAndAliasAndSourcesSurviveSaveAndReload() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let model1 = makeModel(directory: dir)
    await model1.loadDocument()
    let record = record("Preview", id: "p")
    model1.reconcile(with: [record])
    model1.hideApplication(record.id)
    model1.setAlias("PDF Viewer", for: record.id)
    model1.addCustomSource(CustomSourceConfig(id: "s1", rootPath: "/tmp/X", recursive: false, includeGlobs: [], excludeGlobs: [], priority: 5, enabled: true))
    await model1.save()

    let model2 = makeModel(directory: dir)
    await model2.loadDocument()
    #expect(model2.hiddenApplicationIdentifiers.map(\.value) == [record.id.value])
    #expect(model2.alias(for: record.id) == "PDF Viewer")
    #expect(model2.customSources.map(\.id) == ["s1"])
}
