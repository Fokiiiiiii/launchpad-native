import Catalog
import Foundation
import Persistence
import Testing
@testable import Grid

private func record(
    _ name: String,
    id: String,
    backgroundOnly: Bool = false,
    menuBarApp: Bool = false
) -> ApplicationRecord {
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
        isBackgroundOnly: backgroundOnly,
        isMenuBarApp: menuBarApp,
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

@Test @MainActor func hiddenApplicationChangesNotifyObservers() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let app = record("A", id: "a")
    model.reconcile(with: [app])

    var changes = 0
    model.onSearchableRecordsChange = { changes += 1 }
    model.hideApplication(app.id)
    #expect(changes == 1)
    model.unhideApplication(StableAppIdentifier(value: "a"))
    #expect(changes == 2)
}

@Test @MainActor func backgroundSettingsDoNotReloadTheGridObserver() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    var reloads = 0
    model.onChange = { reloads += 1 }
    model.setBackgroundMode(.wallpaper)
    model.setGlassMaterialIntensity(2)
    model.setBlursWallpaper(false)

    #expect(model.glassMaterialIntensity == 1)
    #expect(reloads == 0)
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

@Test @MainActor func reconcileSkipsNotificationWhenCatalogAndLayoutAreUnchanged() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let apps = [record("Apple", id: "a"), record("Banana", id: "b")]

    #expect(model.reconcile(with: apps))
    var notifications = 0
    model.onChange = { notifications += 1 }

    #expect(!model.reconcile(with: apps))
    #expect(notifications == 0)
}

@Test @MainActor func orderedRecordsFollowPagesAndFolderContents() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let apps = [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")]
    model.reconcile(with: apps)

    model.moveItem(fromPage: 0, fromIndex: 2, toPage: 0, toIndex: 0)
    let ordered = model.orderedRecords(from: apps)

    #expect(ordered.map(\.bundleIdentifier) == ["c", "a", "b"])
}

@Test @MainActor func menuBarAndBackgroundAppsFollowGridPlacementPolicy() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    let normal = record("Normal", id: "normal")
    let menuBar = record("CodexBar", id: "menubar", menuBarApp: true)
    let background = record("Agent", id: "agent", backgroundOnly: true)
    model.reconcile(with: [normal, menuBar, background])

    let defaultIDs = Set(model.pages.flatMap { $0 }.compactMap { item -> String? in
        guard case .app(let id) = item else { return nil }
        return model.record(for: id)?.bundleIdentifier
    })
    #expect(defaultIDs == Set(["normal", "menubar"]))

    model.setShowMenuBarApplications(false)
    let disabledIDs = Set(model.pages.flatMap { $0 }.compactMap { item -> String? in
        guard case .app(let id) = item else { return nil }
        return model.record(for: id)?.bundleIdentifier
    })
    #expect(disabledIDs == Set(["normal"]))
    #expect(model.showMenuBarApplications == false)

    model.setShowMenuBarApplications(true)
    let restoredIDs = Set(model.pages.flatMap { $0 }.compactMap { item -> String? in
        guard case .app(let id) = item else { return nil }
        return model.record(for: id)?.bundleIdentifier
    })
    #expect(restoredIDs == Set(["normal", "menubar"]))
}

@Test @MainActor func legacyAndPersistedItemsPruneBackgroundOnlyRecords() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    let normal = record("Normal", id: "normal")
    let background = record("Agent", id: "agent", backgroundOnly: true)
    let normalID = normal.id.asPersistenceIdentifier
    let backgroundID = background.id.asPersistenceIdentifier
    let importedFolder = Folder(
        name: "Imported",
        pages: [[.app(backgroundID), .app(normalID)]]
    )
    let result = LegacyImportResult(
        folders: [importedFolder],
        unplacedAppOrder: [.app(backgroundID), .app(normalID)],
        unresolvedBundleIDs: []
    )

    #expect(model.applyLegacyImportIfFirstRun(result))
    model.reconcile(with: [normal, background])

    let pageIDs = model.pages.flatMap { $0 }.compactMap { item -> StableAppIdentifier? in
        guard case .app(let id) = item else { return nil }
        return id
    }
    #expect(pageIDs == [normalID])
    #expect(model.folders.values.flatMap { $0.pages }.flatMap { $0 }.allSatisfy { item in
        guard case .app(let id) = item else { return true }
        return id == normalID
    })
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

/// Regression: the startup cache path restores a snapshot that can lag the
/// real disk state. Reconciling it as if it were authoritative removed the
/// not-yet-cached apps, and the completed scan then re-appended them as
/// "new" at the end — reshuffling the user's last page on every launch.
@Test @MainActor func reconcileWithANonAuthoritativeSnapshotNeverRemovesPlacedApps() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    let full = [record("Apple", id: "a"), record("Banana", id: "b"), record("Cherry", id: "c")]
    model.reconcile(with: full)
    let arrangementBefore = model.pages

    // A cache that happens to be missing one app must not delete it...
    model.reconcile(with: [record("Apple", id: "a"), record("Banana", id: "b")], prunesMissingItems: false)
    #expect(model.pages == arrangementBefore)

    // ...and the authoritative scan that follows must leave the order intact,
    // rather than re-appending the survivor as if it were newly installed.
    model.reconcile(with: full)
    #expect(model.pages == arrangementBefore)
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

/// Regression test for a real bug found on a live `layout.json`: folders
/// whose entire contents got pruned by `reconcile` (apps no longer found
/// in the catalog scan) kept existing as empty, named shells — only the
/// user-driven `removeFromFolder` path used to check for the resulting
/// empty state and dissolve. `pruneMissingItems` must do the same.
@Test @MainActor func reconcilePrunesFolderContentsAndDissolvesEmptyFolder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")])
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)

    guard case .folder(let folderID) = model.pages[0].first(where: { if case .folder = $0 { return true }; return false }) else {
        Issue.record("expected a folder")
        return
    }
    #expect(model.folders[folderID]?.pages.first?.count == 2) // A and B

    // Both A and B "uninstalled" (no longer in the scan) — C remains.
    model.reconcile(with: [record("C", id: "c")])

    #expect(model.folders[folderID] == nil) // dissolved, not left empty
    let hasFolderReference = model.pages.flatMap { $0 }.contains { if case .folder(folderID) = $0 { return true }; return false }
    #expect(!hasFolderReference)
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

@Test @MainActor func moveItemWithinFolderReordersSamePage() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")])
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 1, destinationPage: 0, destinationIndex: 0)

    guard case .folder(let folderID) = model.pages[0][0] else {
        Issue.record("expected a folder")
        return
    }
    // First join: dragging A (index 0) onto B (index 1) makes a folder
    // holding [B, A] (createOrJoinFolder orders newly-joined folders as
    // [targetItem, draggedItem]). Second join: dragging C (now index 1)
    // onto the folder (now index 0) appends C, giving [B, A, C].
    model.moveItemWithinFolder(folderID, page: 0, fromIndex: 2, toIndex: 0) // C to front

    let bundleIDs = model.folders[folderID]?.pages[0].compactMap { item -> String? in
        guard case .app(let id) = item else { return nil }
        return model.record(for: id)?.bundleIdentifier
    }
    #expect(bundleIDs == ["c", "b", "a"])
}

@Test @MainActor func moveItemWithinFolderIgnoresNoopAndOutOfRange() async throws {
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
    let before = model.folders[folderID]?.pages[0]

    model.moveItemWithinFolder(folderID, page: 0, fromIndex: 0, toIndex: 0) // no-op (same index)
    model.moveItemWithinFolder(folderID, page: 1, fromIndex: 0, toIndex: 0) // out-of-range page
    model.moveItemWithinFolder(folderID, page: 0, fromIndex: 5, toIndex: 0) // out-of-range index
    model.moveItemWithinFolder(FolderID(), page: 0, fromIndex: 0, toIndex: 1) // unknown folder

    let after = model.folders[folderID]?.pages[0]
    #expect(before?.count == after?.count)
    let beforeIDs = before?.compactMap { item -> String? in
        guard case .app(let id) = item else { return nil }
        return model.record(for: id)?.bundleIdentifier
    }
    let afterIDs = after?.compactMap { item -> String? in
        guard case .app(let id) = item else { return nil }
        return model.record(for: id)?.bundleIdentifier
    }
    #expect(beforeIDs == afterIDs)
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

/// Real regression, confirmed via user report: an earlier fix made
/// `updateGridSettings` reflow *unconditionally*, on the mistaken
/// assumption that reflowing at an unchanged capacity is a no-op. It
/// isn't — `reflowPagesToCurrentCapacity()` flattens and tightly repacks
/// every page, which destroys any intentionally non-compact arrangement
/// (a page the user left partially empty, gaps from manual drag-and-drop
/// reordering) every time *any* grid setting was applied, even ones
/// completely unrelated to capacity like icon size. `updateGridSettings`
/// must only reflow when columns*rows actually changes.
@Test @MainActor func applySortModeNameOrdersItemsWithinEachPageAlphabetically() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("Zebra", id: "z"), record("Apple", id: "a"), record("Mango", id: "m")])

    // reconcile already alphabetizes newly-added items, so manually
    // scramble the order first to actually exercise the sort.
    model.moveItem(fromPage: 0, fromIndex: 0, toPage: 0, toIndex: 2)
    let scrambled = model.pages[0].compactMap { item -> String? in
        if case .app(let id) = item { return model.record(for: id)?.displayName }
        return nil
    }
    #expect(scrambled != ["Apple", "Mango", "Zebra"])

    model.applySortMode(.name)

    let sorted = model.pages[0].compactMap { item -> String? in
        if case .app(let id) = item { return model.record(for: id)?.displayName }
        return nil
    }
    #expect(sorted == ["Apple", "Mango", "Zebra"])
    #expect(model.gridSettings.sortMode == .name)
}

@Test @MainActor func applySortModeDateAddedOrdersNewestAddedFirst() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    model.reconcile(with: [record("Apple", id: "a")])
    try await Task.sleep(nanoseconds: 10_000_000) // 10ms — ensure a distinct, later `Date()` for Banana.
    model.reconcile(with: [record("Apple", id: "a"), record("Banana", id: "b")])

    model.applySortMode(.dateAdded)
    let order = model.pages[0].compactMap { item -> String? in
        if case .app(let id) = item { return model.record(for: id)?.displayName }
        return nil
    }
    #expect(order == ["Banana", "Apple"], "Banana was added later, so it sorts first under newest-added-first")
    #expect(model.gridSettings.sortMode == .dateAdded)
}

/// Simulates a real user's grid from before `dateAddedByID` tracking
/// existed: items already placed onto a page, but with no recorded
/// timestamp at all. `GridModel.backfillMissingDateAdded()` (invoked via
/// `reconcile`) must assign each a synthetic, increasing timestamp based on
/// its existing position — apps get appended to the end over time (see
/// `appendToLastPage`), so existing position is the best available proxy
/// for "when added." Under a newest-first sort, that means the item that
/// was already *last* in the page (the most recently appended one,
/// chronologically) sorts first — i.e. the original order reverses.
@Test @MainActor func backfillAssignsIncreasingDatesByExistingPositionForPreExistingItems() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)

    var document = LayoutDocument.empty
    document.pages = [[
        LayoutItem.app(StableAppIdentifier(value: "a")),
        LayoutItem.app(StableAppIdentifier(value: "b")),
        LayoutItem.app(StableAppIdentifier(value: "c"))
    ]]
    #expect(document.dateAddedByID.isEmpty, "sanity check: no dateAdded metadata exists yet")
    try await store.save(document)

    let model = GridModel(layoutStore: store)
    await model.loadDocument()
    // None of these are "new" (all already placed) — this exercises only
    // the backfill path, not the genuinely-new-record stamping path.
    model.reconcile(with: [record("Apple", id: "a"), record("Banana", id: "b"), record("Cherry", id: "c")])

    model.applySortMode(.dateAdded)
    let order = model.pages[0].compactMap { item -> String? in
        if case .app(let id) = item { return model.record(for: id)?.displayName }
        return nil
    }
    #expect(order == ["Cherry", "Banana", "Apple"])
}

@Test @MainActor func applySortModeLastUsedOrdersMostRecentlyLaunchedFirstAndNeverUsedLast() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    let apple = record("Apple", id: "a")
    let banana = record("Banana", id: "b")
    let cherry = record("Cherry", id: "c")
    model.reconcile(with: [apple, banana, cherry])

    model.recordLaunch(for: cherry.id)
    try await Task.sleep(nanoseconds: 10_000_000) // 10ms — ensure a distinct, later `Date()` for Apple's launch.
    model.recordLaunch(for: apple.id)
    // Banana is never launched — it should sink to the end, not disturb
    // the ordering of apps that do have real lastUsed data.

    model.applySortMode(.lastUsed)
    let order = model.pages[0].compactMap { item -> String? in
        if case .app(let id) = item { return model.record(for: id)?.displayName }
        return nil
    }
    #expect(order == ["Apple", "Cherry", "Banana"])
    #expect(model.gridSettings.sortMode == .lastUsed)
}

@Test @MainActor func reorganizePagesRepacksTightlyUnderCurrentCapacity() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")])

    // Manually leave a gap: move C to a fresh second page, leaving page 0
    // under-full even though everything would fit on one page.
    model.moveItem(fromPage: 0, fromIndex: 2, toPage: 1, toIndex: 0)
    #expect(model.pages.count == 2)

    model.reorganizePages()

    #expect(model.pages.count == 1)
    #expect(model.pages[0].count == 3)
}

@Test @MainActor func updatingSettingsWithoutCapacityChangePreservesNonCompactArrangement() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    var settings = GridSettings.default
    settings.columns = 6
    settings.rows = 3 // capacity 18
    var document = LayoutDocument.empty
    document.gridSettings = settings
    // Deliberately non-compact: 10 + 8 = 18 items, well under 2 full
    // pages' worth, split across 2 pages as if the user dragged some
    // items to a second page on purpose.
    document.pages = [
        (0..<10).map { LayoutItem.app(StableAppIdentifier(value: "app\($0)")) },
        (10..<18).map { LayoutItem.app(StableAppIdentifier(value: "app\($0)")) }
    ]
    let store = LayoutStore(directory: dir)
    try await store.save(document)

    let model = makeModel(directory: dir)
    await model.loadDocument()
    #expect(model.pages.map(\.count) == [10, 8], "sanity check: loaded arrangement is as saved")

    // Change only horizontalSpacing — columns/rows (and therefore capacity)
    // stay the same.
    var updated = model.gridSettings
    updated.horizontalSpacing = updated.horizontalSpacing + 8
    model.updateGridSettings(updated)

    #expect(model.pages.map(\.count) == [10, 8], "capacity-unchanged settings update must not repack pages")
}

// MARK: - Folder page packing

private func appItem(_ id: String) -> LayoutItem {
    .app(StableAppIdentifier(value: id))
}

private func bundleIDs(_ pages: [[LayoutItem]]) -> [[String]] {
    pages.map { page in
        page.compactMap { item -> String? in
            guard case .app(let id) = item else { return nil }
            return id.value
        }
    }
}

/// The legacy importer puts every item of an imported folder on one page
/// regardless of count, which was invisible while the opened folder flattened
/// all of its pages into one list — but a page is now something the user swipes
/// between, so an over-full page has to be split.
@Test func repackingSplitsAnOverfullPageWithoutReorderingAnything() {
    let overfull = [(1...20).map { appItem("a\($0)") }]
    let repacked = GridModel.folderPagesRepacked(overfull, capacity: 9)
    #expect(repacked.map(\.count) == [9, 9, 2])
    #expect(bundleIDs(repacked).flatMap { $0 } == (1...20).map { "a\($0)" })
}

/// Dragging an item out of a middle page used to leave a hole there while later
/// pages stayed full — a gap the user can now see.
@Test func repackingClosesAHoleLeftInAMiddlePage() {
    let holed = [
        (1...9).map { appItem("a\($0)") },
        [appItem("b1"), appItem("b2")],          // hole: page is short…
        (1...9).map { appItem("c\($0)") }        // …while a later page is full
    ]
    let repacked = GridModel.folderPagesRepacked(holed, capacity: 9)
    #expect(repacked.map(\.count) == [9, 9, 2])
    #expect(bundleIDs(repacked)[1].first == "b1")
    #expect(bundleIDs(repacked)[2] == ["c8", "c9"])
}

/// Correctly-packed folders — every real folder in a normal layout — must come
/// back untouched, so this can be applied unconditionally on load.
@Test func repackingLeavesAlreadyCorrectPagesAlone() {
    let exactlyFull = [(1...9).map { appItem("a\($0)") }]
    #expect(GridModel.folderPagesRepacked(exactlyFull, capacity: 9) == exactlyFull)

    let partial = [[appItem("a"), appItem("b")]]
    #expect(GridModel.folderPagesRepacked(partial, capacity: 9) == partial)

    let empty: [[LayoutItem]] = [[]]
    #expect(GridModel.folderPagesRepacked(empty, capacity: 9) == empty)
}

@Test func repackingSurvivesADegenerateCapacity() {
    let items = [[appItem("a"), appItem("b")]]
    #expect(GridModel.folderPagesRepacked(items, capacity: 0).map(\.count) == [1, 1])
}

/// The end-to-end path: a folder loaded with an over-full page is healed, and
/// the model reports that it changed so the caller knows to persist it.
@Test @MainActor func loadingAFolderWithAnOverfullPageRepacksIt() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)
    var document = LayoutDocument.empty
    let folder = Folder(name: "Imported", pages: [(1...14).map { appItem("a\($0)") }])
    document.folders = [folder.id: folder]
    document.pages = [[.folder(folder.id)]]
    try await store.save(document)

    let model = GridModel(layoutStore: store)
    await model.loadDocument()

    #expect(model.folders[folder.id]?.pages.map(\.count) == [9, 5])
    // Idempotent: a second pass has nothing left to do.
    #expect(model.normalizeFolderPages() == false)
}

/// Dropping one app onto another builds a folder through the same capacity path
/// as every other insertion, rather than assigning a page literal.
@Test @MainActor func aNewlyCreatedFolderIsPackedByTheSameRule() async throws {
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
    #expect(model.folders[folderID]?.pages.count == 1)
    #expect(model.folders[folderID]?.pages[0].count == 2)
}

/// Dropping onto a page that is already full used to make it one item longer
/// than the grid can draw, so the item pushed past the last slot was laid out
/// below the viewport and disappeared until the next launch repacked the whole
/// layout.
@Test @MainActor func droppingOntoAFullPagePushesTheOverflowOntoTheNextPage() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    var settings = model.gridSettings
    settings.columns = 2
    settings.rows = 2 // capacity 4
    model.updateGridSettings(settings)

    let records = (0..<6).map { index in
        record("App \(index)", id: "com.example.app\(index)")
    }
    model.reconcile(with: records)
    #expect(model.pages.map(\.count) == [4, 2], "the fixture should start with one full page and one partial")

    let movedID = model.pages[1][1]
    let displacedID = model.pages[0][3]
    model.moveItem(fromPage: 1, fromIndex: 1, toPage: 0, toIndex: 0)

    #expect(
        model.pages[0].count == 4,
        "page 0 holds \(model.pages[0].count) items with a capacity of 4 — the extra one is drawn outside the viewport"
    )
    #expect(model.pages[0][0] == movedID)
    #expect(model.pages[1].first == displacedID, "the item pushed off page 0 should land at the head of page 1")
    #expect(model.pages.flatMap { $0 }.count == 6, "nothing may be lost while absorbing the drop")
}

@Test @MainActor func overflowFromAFullLastPageOpensANewOne() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    var settings = model.gridSettings
    settings.columns = 2
    settings.rows = 1 // capacity 2
    model.updateGridSettings(settings)

    let records = (0..<4).map { index in
        record("Full \(index)", id: "com.example.full\(index)")
    }
    model.reconcile(with: records)
    #expect(model.pages.map(\.count) == [2, 2])

    // Forward, onto a full last page: the item pushed off the end has nowhere
    // to go, so a page has to open for it. (Moving the other way instead frees
    // a slot on the source page, which absorbs the overflow — hence the
    // direction here.)
    model.moveItem(fromPage: 0, fromIndex: 0, toPage: 1, toIndex: 0)

    #expect(model.pages.map(\.count) == [1, 2, 1], "the cascade should add a page at the end rather than overfill the last one")
    #expect(model.pages.flatMap { $0 }.count == 4)
}

@Test @MainActor func reorderingWithinAFullPageIsUnaffected() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    var settings = model.gridSettings
    settings.columns = 2
    settings.rows = 2 // capacity 4
    model.updateGridSettings(settings)

    let records = (0..<4).map { index in
        record("Same \(index)", id: "com.example.same\(index)")
    }
    model.reconcile(with: records)
    let last = model.pages[0][3]

    model.moveItem(fromPage: 0, fromIndex: 3, toPage: 0, toIndex: 0)

    #expect(model.pages.map(\.count) == [4], "a same-page reorder does not change any page's size")
    #expect(model.pages[0][0] == last)
}

/// The search index is built from the catalog plus the aliases, so renaming an
/// app has to reach it the same way hiding one does. Without this the rename
/// landed in the layout but the search list kept the old name until the next
/// catalog scan.
@Test @MainActor func renamingAnAppNotifiesTheSearchIndex() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let app = record("Notes", id: "com.apple.Notes")
    model.reconcile(with: [app])

    var changes = 0
    model.onSearchableRecordsChange = { changes += 1 }
    model.setAlias("notepad", for: app.id)
    #expect(changes == 1)
    #expect(model.displayName(for: app) == "notepad")
    model.setAlias(nil, for: app.id)
    #expect(changes == 2)
    #expect(model.displayName(for: app) == "Notes")
}

/// `removeFromFolder` compacts the folder's pages after taking an item out;
/// pruning did not, so a folder that lost apps to a rescan kept a hole in
/// whichever page they were on. The folder is paged, so the user swipes to a
/// half-empty page — or past a completely empty one — until the next launch.
@Test @MainActor func pruningAFolderCompactsItsPages() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    var settings = model.gridSettings
    settings.folderGridSize = 2
    model.updateGridSettings(settings)

    let all = (0..<6).map { record("App \($0)", id: "app\($0)") }
    model.reconcile(with: all)
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    guard case .folder(let folderID) = model.pages[0][0] else {
        Issue.record("expected a folder")
        return
    }
    // Fill it past one page: capacity 2, so 6 apps land as [2, 2, 2].
    for _ in 0..<4 {
        model.createOrJoinFolder(sourcePage: 0, sourceIndex: 1, destinationPage: 0, destinationIndex: 0)
    }
    #expect(model.folders[folderID]?.pages.map(\.count) == [2, 2, 2], "the fixture should span three folder pages")
    let secondPage = try #require(model.folders[folderID]?.pages[1])

    // One of the apps on the middle page disappears from the catalog.
    guard case .app(let victim) = secondPage[0] else {
        Issue.record("expected an app")
        return
    }
    model.reconcile(with: all.filter { $0.id.value != victim.value })

    let pages = try #require(model.folders[folderID]?.pages)
    #expect(pages.map(\.count) == [2, 2, 1], "pages: \(pages.map(\.count)) — the hole was left where the app was removed")
    #expect(pages.flatMap { $0 }.count == 5)
}

/// The cascade must push off what was already on the page, never the item the
/// user just dropped: the drag settles onto a slot on *this* page, so sending
/// the dropped item away makes the icon appear to fly off the slot it landed
/// on, and the animation points at a different app.
@Test @MainActor func droppingAtTheEndOfAFullPageKeepsTheDroppedItemThere() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    var settings = model.gridSettings
    settings.columns = 2
    settings.rows = 2 // capacity 4
    model.updateGridSettings(settings)

    let records = (0..<6).map { record("App \($0)", id: "app\($0)") }
    model.reconcile(with: records)
    #expect(model.pages.map(\.count) == [4, 2])

    let moved = model.pages[1][0]
    let previousLast = model.pages[0][3]
    // Past the last slot of a page that is already full — what
    // `ItemDragController` passes when the drop lands beyond the last icon.
    model.moveItem(fromPage: 1, fromIndex: 0, toPage: 0, toIndex: 4)

    #expect(model.pages[0].contains(moved), "the dropped item must stay on the page it was dropped on")
    #expect(model.pages[0].last == moved)
    #expect(model.pages[1].first == previousLast, "the page's own last item is the one that gets displaced")
    #expect(model.pages[0].count == 4)
    #expect(model.pages.flatMap { $0 }.count == 6)
}

/// Dragging an app out of a folder is the other way onto a page, and it had no
/// capacity check at all — the same disappearing act as a drop onto a full page.
@Test @MainActor func draggingOutOfAFolderOntoAFullPageCascades() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    var settings = model.gridSettings
    settings.columns = 2
    settings.rows = 2 // capacity 4
    model.updateGridSettings(settings)

    // Three loose apps plus a folder holding two: page 0 is exactly full.
    let records = (0..<5).map { record("App \($0)", id: "app\($0)") }
    model.reconcile(with: records)
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    // Folding two apps into one tile left a gap and pushed the fifth app onto
    // page 1; bring it back so page 0 is exactly full.
    model.moveItem(fromPage: 1, fromIndex: 0, toPage: 0, toIndex: 3)
    #expect(model.pages[0].count == 4, "the fixture should leave page 0 exactly full")
    guard case .folder(let folderID) = model.pages[0].first(where: { if case .folder = $0 { return true } else { return false } }) else {
        Issue.record("expected a folder on page 0")
        return
    }

    model.removeFromFolder(folderID, folderPage: 0, folderIndex: 0, toPage: 0)

    #expect(
        model.pages[0].count == 4,
        "page 0 holds \(model.pages[0].count) with a capacity of 4 — the extra one is drawn outside the viewport"
    )
    #expect(model.pages.count > 1 && model.pages[1].count == 1, "the displaced item should land on the next page")
    let placed = model.pages.flatMap { $0 }
    #expect(placed.count == 5)
}
