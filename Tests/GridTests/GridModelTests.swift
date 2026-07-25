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

@Test @MainActor func reconcileAppendsNewAppsAlphabetically() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    model.reconcile(with: [record("Zebra", id: "z"), record("Apple", id: "a")])

    let appIDs = model.pages[0].compactMap { item -> String? in
        if case .app(let id) = item { return id.value }
        return nil
    }
    #expect(appIDs.count == 2)
    #expect(model.record(for: StableAppIdentifier(value: appIDs[0]))?.displayName == "Apple")
    #expect(model.record(for: StableAppIdentifier(value: appIDs[1]))?.displayName == "Zebra")
}

@Test @MainActor func reconcilePrunesUninstalledApps() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    model.reconcile(with: [record("Apple", id: "a"), record("Banana", id: "b")])
    #expect(model.pages[0].count == 2)

    model.reconcile(with: [record("Apple", id: "a")]) // Banana "uninstalled"
    #expect(model.pages[0].count == 1)
}

@Test @MainActor func reconcileStartsNewPageWhenCapacityExceeded() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    // default grid is 7x5 = 35 capacity
    let records = (0..<40).map { record("App\($0)", id: "id\($0)") }
    model.reconcile(with: records)

    #expect(model.pages.count == 2)
    #expect(model.pages[0].count == 35)
    #expect(model.pages[1].count == 5)
}

@Test @MainActor func moveItemReordersWithinAndAcrossPages() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")])

    model.moveItem(fromPage: 0, fromIndex: 2, toPage: 0, toIndex: 0) // C to front
    let bundleIDs = model.pages[0].compactMap { item -> String? in
        guard case .app(let id) = item else { return nil }
        return model.record(for: id)?.bundleIdentifier
    }
    #expect(bundleIDs == ["c", "a", "b"])
}

@Test @MainActor func draggingOneAppOntoAnotherCreatesFolder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b")])

    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)

    #expect(model.pages[0].count == 1)
    guard case .folder(let folderID) = model.pages[0][0] else {
        Issue.record("expected a folder")
        return
    }
    #expect(model.folders[folderID]?.pages.first?.count == 2)
}

@Test @MainActor func draggingIntoExistingFolderAddsToIt() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")])

    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    // Now pages[0] = [folder, C] (folder took A+B's slot, C shifted down)
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 1, destinationPage: 0, destinationIndex: 0)

    #expect(model.pages[0].count == 1)
    guard case .folder(let folderID) = model.pages[0][0] else {
        Issue.record("expected a folder")
        return
    }
    #expect(model.folders[folderID]?.pages.first?.count == 3)
}

@Test @MainActor func removeFromFolderDissolvesEmptyFolder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b")])
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)

    guard case .folder(let folderID) = model.pages[0][0] else {
        Issue.record("expected a folder")
        return
    }

    model.removeFromFolder(folderID, folderPage: 0, folderIndex: 0, toPage: 0)
    #expect(model.folders[folderID] != nil) // still has 1 item

    model.removeFromFolder(folderID, folderPage: 0, folderIndex: 0, toPage: 0)
    #expect(model.folders[folderID] == nil) // dissolved once empty
}

@Test @MainActor func renameFolderUpdatesName() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b")])
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)

    guard case .folder(let folderID) = model.pages[0][0] else {
        Issue.record("expected a folder")
        return
    }
    model.renameFolder(folderID, to: "Utilities")
    #expect(model.folders[folderID]?.name == "Utilities")
}

@Test @MainActor func saveThenReloadPreservesArrangement() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let model1 = makeModel(directory: dir)
    await model1.loadDocument()
    model1.reconcile(with: [record("A", id: "a"), record("B", id: "b")])
    model1.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    model1.renameFolder({ if case .folder(let id) = model1.pages[0][0] { return id } else { fatalError() } }(), to: "MyFolder")
    await model1.save()

    let model2 = makeModel(directory: dir)
    await model2.loadDocument()
    #expect(model2.folders.values.first?.name == "MyFolder")
    #expect(model2.pages[0].count == 1)
}

/// Real-world bug, confirmed on an actual corrupted document: a page
/// persisted under a larger columns*rows capacity (e.g. 7x5 = 35) still had
/// 34-35 items after the user reduced the grid to 6x3 = 18. PagedGridLayout
/// positions item N at row = N / columns, so anything past the new row
/// count renders below the visible page and never appears — "some grid
/// icons disappear." `updateGridSettings` must reflow pages, not just
/// record the new capacity.
@Test @MainActor func reducingGridCapacityReflowsOversizedPages() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    let records = (0..<40).map { record("App \($0)", id: "app\($0)") }
    model.reconcile(with: records)
    // Default GridSettings is 7x5 = 35 capacity: reconcile should have
    // packed 35 onto page 0 and overflowed the rest onto page 1.
    #expect(model.pages[0].count == 35)

    var shrunk = model.gridSettings
    shrunk.columns = 6
    shrunk.rows = 3 // capacity 18
    model.updateGridSettings(shrunk)

    for page in model.pages {
        #expect(page.count <= 18, "page has \(page.count) items, exceeding capacity 18")
    }
    #expect(model.pages.flatMap { $0 }.count == 40, "reflow must not lose or duplicate items")
}

/// Same bug, but for a document that was *already* corrupted before this
/// fix existed (i.e. persisted to disk with an oversized page under an
/// older, larger capacity) — `loadDocument()` must self-heal it, not just
/// prevent new corruption going forward.
@Test @MainActor func loadingAnAlreadyCorruptedDocumentSelfHeals() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    var corrupted = LayoutDocument.empty
    var smallCapacitySettings = GridSettings.default
    smallCapacitySettings.columns = 6
    smallCapacitySettings.rows = 3 // capacity 18
    corrupted.gridSettings = smallCapacitySettings
    corrupted.pages = [
        (0..<34).map { LayoutItem.app(StableAppIdentifier(value: "app\($0)")) }
    ]
    let store = LayoutStore(directory: dir)
    try await store.save(corrupted)

    let model = makeModel(directory: dir)
    await model.loadDocument()

    for page in model.pages {
        #expect(page.count <= 18)
    }
    #expect(model.pages.flatMap { $0 }.count == 34)
}

/// The reverse direction of the same bug, confirmed via a real user report:
/// increasing rows from 3 to 4 changed the layout (shorter cells, an extra
/// visible row) but left existing pages grouped at the *old*, smaller
/// capacity — the newly-available row just sat empty instead of pulling
/// items up from later pages. `updateGridSettings` previously only reflowed
/// when an existing page *exceeded* the new capacity, never when capacity
/// grew, since growing a capacity never makes an existing page exceed it.
@Test @MainActor func increasingGridCapacityConsolidatesUnderfilledPages() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    var small = model.gridSettings
    small.columns = 6
    small.rows = 3 // capacity 18
    model.updateGridSettings(small)

    let records = (0..<40).map { record("App \($0)", id: "app\($0)") }
    model.reconcile(with: records)
    // 40 items at capacity 18 should pack as [18, 18, 4].
    #expect(model.pages.map(\.count) == [18, 18, 4])

    var grown = model.gridSettings
    grown.columns = 6
    grown.rows = 4 // capacity 24
    model.updateGridSettings(grown)

    // The same 40 items must now be repacked at the larger capacity, not
    // left in their old [18, 18, 4] grouping with the extra row empty.
    #expect(model.pages.map(\.count) == [24, 16], "pages must be consolidated to the new, larger capacity")
    #expect(model.pages.flatMap { $0 }.count == 40, "reflow must not lose or duplicate items")
}
