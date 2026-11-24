import Catalog
import Foundation
import Persistence
import Testing
@testable import Grid

import Darwin

import AppKit

import SQLite3

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

/// The importer puts a whole folder on one page, and the split to the folder
/// page size used to happen only when a saved layout was loaded — so a first
/// import left a big folder with more icons than its panel can show.
@Test @MainActor func aLegacyFolderLargerThanAFolderPageIsSplitAtOnce() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    let limit = model.gridSettings.folderGridSize
    let apps = (0..<(limit * 2 + 3)).map { record("App\($0)", id: "app\($0)") }
    let folder = Folder(name: "Big", pages: [apps.map { .app($0.id.asPersistenceIdentifier) }])
    let result = LegacyImportResult(
        folders: [folder],
        unplacedAppOrder: [.folder(folder.id)],
        unresolvedBundleIDs: []
    )

    #expect(model.applyLegacyImportIfFirstRun(result))

    let imported = try #require(model.folders[folder.id])
    #expect(imported.pages.count == 3)
    #expect(imported.pages.allSatisfy { $0.count <= limit })
    #expect(imported.pages.flatMap { $0 }.count == apps.count, "nothing was dropped by the split")
}

@Test @MainActor func failedLegacyImportDoesNotModifyTheGrid() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    var changed = false
    model.onChange = { changed = true }
    let result = LegacyImportResult(folders: [], unplacedAppOrder: [], unresolvedBundleIDs: [], succeeded: false)
    #expect(!model.applyLegacyImportIfFirstRun(result))
    #expect(model.hasNoArrangement)
    #expect(!changed)
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

@Test @MainActor func removingAppsEliminatesEmptyPages() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let records = (0..<71).map { record(String(format: "App%03d", $0), id: "id\($0)") }
    model.reconcile(with: records)
    #expect(model.pages.map(\.count) == [35, 35, 1])

    let remaining = Array(records.prefix(35)) + [records[70]]
    model.reconcile(with: remaining, prunesMissingItems: false)
    #expect(model.pages.count == 3)
    model.reconcile(with: remaining)
    #expect(model.pages.map(\.count) == [35, 1])

    model.reconcile(with: [])
    #expect(model.pages.count == 1)
    #expect(model.pages[0].isEmpty)
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

@Test @MainActor func benchmarkSingleItemMoves() async {
    guard ProcessInfo.processInfo.environment["LAUNCHPAD_BENCHMARK"] == "1" else { return }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<1000).map { record("App \($0)", id: "org.example.\($0)") })
    var reference = model.pages
    let startSwift = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<500 {
        let item = reference[0].remove(at: 0)
        reference[0].insert(item, at: 10)
    }
    let swift = DispatchTime.now().uptimeNanoseconds - startSwift
    let startRust = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<500 { model.moveItem(fromPage: 0, fromIndex: 0, toPage: 0, toIndex: 10) }
    let rust = DispatchTime.now().uptimeNanoseconds - startRust
    #expect(model.pages == reference)
    print("LAYOUT_BENCH apps=1000 moves=500 swift_ns=\(swift) rust_ns=\(rust)")
}

@Test @MainActor func benchmarkGridModelMemory() async {
    guard ProcessInfo.processInfo.environment["LAUNCHPAD_BENCHMARK"] == "1" else { return }
    let count = Int(ProcessInfo.processInfo.environment["LAUNCHPAD_MEMORY_ITEMS"] ?? "1000") ?? 1000
    guard (1...10_000).contains(count) else { return }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let records = (0..<count).map { record("App \($0)", id: "org.example.\($0)") }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    func peak() -> Int {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        return usage.ru_maxrss
    }
    let baseline = peak()
    #expect(model.reconcile(with: records))
    #expect(model.pages.flatMap { $0 }.count == count)
    print("MEMORY_BENCH scenario=grid-model items=\(count) baseline_bytes=\(baseline) peak_bytes=\(peak())")
    withExtendedLifetime(model) {}
}

@Test @MainActor func benchmarkStableGridReconcile() async {
    guard ProcessInfo.processInfo.environment["LAUNCHPAD_BENCHMARK"] == "1" else { return }
    let count = Int(ProcessInfo.processInfo.environment["LAUNCHPAD_MEMORY_ITEMS"] ?? "4096") ?? 4096
    guard (1...10_000).contains(count) else { return }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let records = (0..<count).map { record("App \($0)", id: "org.example.\($0)") }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    #expect(model.reconcile(with: records))
    func peak() -> Int { var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage); return usage.ru_maxrss }
    let baseline = peak()
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<5 { #expect(!model.reconcile(with: records)) }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    print("MEMORY_BENCH scenario=stable-grid items=\(count) baseline_bytes=\(baseline) peak_bytes=\(peak()) elapsed_ns=\(elapsed)")
    withExtendedLifetime(model) {}
}

@Test @MainActor func movingAGroupPreservesOrderAndRejectsStaleItems() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c"), record("D", id: "d")])
    let original = model.pages[0]
    let selected: Set<LayoutItem> = [original[0], original[2]]
    let leader = model.pages[0][0]
    #expect(model.moveItems(selected, leader: leader, toPage: 0, toIndex: 3) == 0)
    #expect(model.pages == [[original[1], original[3], original[0], original[2]]])
    let missing = LayoutItem.app(StableAppIdentifier(value: "missing"))
    #expect(model.moveItems([leader, missing], leader: leader, toPage: 0, toIndex: 0) == nil)
    #expect(model.pages == [[original[1], original[3], original[0], original[2]]])
}

@Test @MainActor func groupDropCreatesFolderAndPreservesItsApps() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")])
    let a = model.pages[0][0]
    let b = model.pages[0][1]
    let target = model.pages[0][2]
    #expect(model.moveItems([a, b], leader: a, toPage: 0, toIndex: 0, folderTarget: target) == 0)
    guard case .folder(let id) = model.pages[0][0], let folder = model.folders[id] else {
        Issue.record("expected folder")
        return
    }
    #expect(folder.pages == [[target, a, b]])
}

@Test @MainActor func groupMoveRemovesAnEmptyPageAndPreservesCapacity() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    var settings = model.gridSettings
    settings.columns = 2
    settings.rows = 1
    model.updateGridSettings(settings)
    model.reconcile(with: (0..<4).map { record("App \($0)", id: "app\($0)") })
    let original = model.pages
    let group = Set(original[0])
    #expect(model.moveItems(group, leader: original[0][0], toPage: 1, toIndex: 0) == 0)
    #expect(model.pages == [original[0], original[1]])
    #expect(model.pages.allSatisfy { !$0.isEmpty && $0.count <= 2 })
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

@Test @MainActor func undoPutsBackTheLastChangesInReverseOrder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let c = record("C", id: "c")
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), c])
    let original = model.pages

    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    let withFolder = model.pages
    model.hideApplication(c.id)

    #expect(model.undo())
    #expect(model.pages == withFolder)
    #expect(model.hiddenApplicationIdentifiers.isEmpty)
    #expect(model.undo())
    #expect(model.pages == original)
    #expect(model.folders.isEmpty)
    #expect(!model.undo())
}

@Test @MainActor func ungroupingAllFoldersAppendsItemsAndCanBeUndone() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c"), record("D", id: "d")])
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    let original = model.pages
    let originalFolders = model.folders
    guard case .folder(let id) = original[0][0], let folder = model.folders[id] else {
        Issue.record("folder missing"); return
    }
    let expected = Array(original[0].dropFirst()) + folder.pages.flatMap { page in page }
    model.ungroupAllFolders()
    #expect(model.pages[0] == expected)
    #expect(model.folders.isEmpty)
    #expect(model.undo())
    #expect(model.pages == original)
    #expect(model.folders == originalFolders)
}

@Test @MainActor func ungroupingAllFoldersCarriesOverflowWithoutLosingApps() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let apps = (0..<36).map { index in record("App" + String(index), id: "id" + String(index)) }
    model.reconcile(with: apps)
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    model.moveItem(fromPage: 1, fromIndex: 0, toPage: 0, toIndex: 34)
    let original = model.pages
    let originalFolders = model.folders
    model.ungroupAllFolders()
    #expect(model.pages.map { page in page.count } == [35, 1])
    #expect(Set(model.pages.flatMap { page in page }) == Set(apps.map { app in .app(app.id.asPersistenceIdentifier) }))
    #expect(model.undo())
    #expect(model.pages == original)
    #expect(model.folders == originalFolders)
}

@Test @MainActor func hidingMultipleAppsCanBeUndoneTogether() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let a = record("A", id: "a")
    let b = record("B", id: "b")
    let c = record("C", id: "c")
    model.reconcile(with: [a, b, c])
    let original = model.pages
    model.hideApplications([a.id, b.id])
    #expect(Set(model.hiddenApplicationIdentifiers) == Set([a.id.asPersistenceIdentifier, b.id.asPersistenceIdentifier]))
    #expect(model.undo())
    #expect(model.pages == original)
    #expect(model.hiddenApplicationIdentifiers.isEmpty)
    #expect(!model.undo())
}

@Test @MainActor func selectingAllItemsIncludesEveryPage() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let view = NSView()
    let scroll = NSScrollView()
    let collection = GridCollectionView()
    let drag = ItemDragController(model: model, layout: PagedGridLayout(), collectionView: collection, scrollView: scroll, view: view, callbacks: .init(currentPage: { 0 }, commitPageChange: { _ in }, prefetchIcons: { _ in }, neighborPage: { _, _ in nil }, activateItem: { _ in }, clearKeyboardSelection: {}))
    #expect(!drag.selectAllItems())
    let apps = (0..<60).map { index in record("App" + String(index), id: "id" + String(index)) }
    model.reconcile(with: apps)
    #expect(model.pages.count > 1)
    #expect(drag.selectAllItems())
    #expect(drag.groupSelection == Set(model.pages.flatMap { page in page }))
    drag.clearGroupSelection()
    #expect(drag.groupSelection.isEmpty)
}

@Test @MainActor func backgroundClickAndMarqueeAreDistinguished() {
    let collection = GridCollectionView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    collection.collectionViewLayout = NSCollectionViewFlowLayout()
    var clicks = 0
    var starts: [Bool] = []
    var rects: [NSRect] = []
    var ends = 0
    collection.onBackgroundClick = { clicks += 1 }
    collection.onMarqueeBegin = { starts.append($0) }
    collection.onMarqueeChange = { rects.append($0) }
    collection.onMarqueeEnd = { ends += 1 }
    func event(_ type: NSEvent.EventType, _ point: NSPoint, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    collection.mouseDown(with: event(.leftMouseDown, NSPoint(x: 10, y: 10)))
    #expect(clicks == 0)
    collection.mouseUp(with: event(.leftMouseUp, NSPoint(x: 10, y: 10)))
    #expect(clicks == 1)
    collection.mouseDown(with: event(.leftMouseDown, NSPoint(x: 10, y: 10), .command))
    collection.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 40, y: 50), .command))
    #expect(collection.isMarqueeActive)
    collection.mouseUp(with: event(.leftMouseUp, NSPoint(x: 40, y: 50), .command))
    #expect(!collection.isMarqueeActive)
    #expect(starts == [true])
    let start = collection.convert(NSPoint(x: 10, y: 10), from: nil)
    let end = collection.convert(NSPoint(x: 40, y: 50), from: nil)
    let expected = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
    #expect(rects == [expected])
    #expect(ends == 1)
    #expect(clicks == 1)
    var itemUps = 0
    collection.onItemMouseUp = { _ in itemUps += 1 }
    collection.mouseDown(with: event(.leftMouseDown, NSPoint(x: 10, y: 10)))
    collection.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 40, y: 50)))
    collection.cancelMarquee()
    collection.mouseUp(with: event(.leftMouseUp, NSPoint(x: 40, y: 50)))
    #expect(ends == 2)
    #expect(clicks == 1)
    #expect(itemUps == 0)
}

@Test @MainActor func marqueeSelectionUpdatesWhenTheRectangleShrinks() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")])
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.reload()
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first,
          let collection = scroll.documentView as? GridCollectionView,
          let first = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
          let second = collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame else {
        Issue.record("grid geometry unavailable"); return
    }
    collection.onMarqueeBegin?(false)
    collection.onMarqueeChange?(first.union(second))
    #expect(collection.menuProvider?(IndexPath(item: 0, section: 0))?.items.first?.submenu != nil)
    collection.onMarqueeChange?(first)
    #expect(collection.menuProvider?(IndexPath(item: 0, section: 0))?.items.first?.submenu == nil)
    collection.onMarqueeEnd?()
    collection.onMarqueeBegin?(true)
    collection.onMarqueeChange?(second)
    #expect(collection.menuProvider?(IndexPath(item: 0, section: 0))?.items.first?.submenu != nil)
    collection.onMarqueeEnd?()
}

@Test @MainActor func cancelledItemPressDoesNotLaunchOnLaterMouseUp() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a")])
    var launches = 0
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in launches += 1 }, onBackgroundClick: {})
    controller.loadViewIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first,
          let collection = scroll.documentView as? GridCollectionView,
          let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
        Issue.record("grid unavailable"); return
    }
    collection.onItemMouseDown?(IndexPath(item: 0, section: 0), click)
    controller.cancelItemDragIfNeeded()
    collection.onItemMouseUp?(click)
    #expect(launches == 0)
}

@Test @MainActor func selectedAppsExposeBatchMenuAndCanBeHiddenTogether() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let apps = (0..<60).map { index in record("App" + String(index), id: "id" + String(index)) }
    model.reconcile(with: apps)
    let original = model.pages
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.loadViewIfNeeded()
    #expect(controller.selectAllItems())
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first,
          let collection = scroll.documentView as? GridCollectionView,
          let menu = collection.menuProvider?(IndexPath(item: 0, section: 0)),
          let hide = menu.items.last as? ClosureMenuItem else {
        Issue.record("batch menu is unavailable")
        return
    }
    #expect(menu.items.first?.submenu?.items.count == original.count)
    hide.invoke()
    #expect(model.hiddenApplicationIdentifiers.count == apps.count)
    #expect(model.undo())
    #expect(model.pages == original)
}

@Test @MainActor func selectedAppsCanBeGroupedAndUndone() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")])
    let original = model.pages
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.loadViewIfNeeded()
    #expect(controller.selectAllItems())
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first,
          let collection = scroll.documentView as? GridCollectionView,
          let menu = collection.menuProvider?(IndexPath(item: 0, section: 0)),
          let group = menu.items.dropFirst().first as? ClosureMenuItem else {
        Issue.record("group menu is unavailable")
        return
    }
    group.invoke()
    guard case .folder(let id) = model.pages[0][0], let folder = model.folders[id] else {
        Issue.record("group did not create a folder")
        return
    }
    #expect(folder.pages.flatMap { page in page } == original.flatMap { page in page })
    #expect(model.undo())
    #expect(model.pages == original)
}

@Test @MainActor func selectedAppsOpenInGridOrder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let apps = [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")]
    model.reconcile(with: apps)
    var launched: [StableAppID] = []
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { app in launched.append(app.id) }, onBackgroundClick: {})
    controller.loadViewIfNeeded()
    #expect(controller.selectAllItems())
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first,
          let collection = scroll.documentView as? GridCollectionView,
          let menu = collection.menuProvider?(IndexPath(item: 0, section: 0)),
          let open = menu.items.dropLast().last as? ClosureMenuItem else {
        Issue.record("open menu is unavailable"); return
    }
    open.invoke()
    #expect(launched == apps.map { app in app.id })
}

@Test @MainActor func staleBatchMenuDoesNotHideRemainingApps() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let apps = [record("A", id: "a"), record("B", id: "b")]
    model.reconcile(with: apps)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.loadViewIfNeeded()
    #expect(controller.selectAllItems())
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first,
          let collection = scroll.documentView as? GridCollectionView,
          let menu = collection.menuProvider?(IndexPath(item: 0, section: 0)),
          let hide = menu.items.last as? ClosureMenuItem else {
        Issue.record("batch menu unavailable"); return
    }
    model.hideApplication(apps[0].id)
    hide.invoke()
    #expect(Set(model.hiddenApplicationIdentifiers) == Set([apps[0].id.asPersistenceIdentifier]))
}

@Test @MainActor func selectedAppsCanMoveIntoExistingFolder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c"), record("D", id: "d")])
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    let original = model.pages
    guard case .folder(let id) = model.pages[0][0] else { Issue.record("folder missing"); return }
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.loadViewIfNeeded()
    #expect(controller.selectAllItems())
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first,
          let collection = scroll.documentView as? GridCollectionView,
          let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
        Issue.record("grid unavailable"); return
    }
    collection.onItemMouseDown?(IndexPath(item: 0, section: 0), click)
    guard let menu = collection.menuProvider?(IndexPath(item: 1, section: 0)),
          let destination = menu.items.dropFirst().first?.submenu?.items.first as? ClosureMenuItem else {
        Issue.record("folder menu unavailable"); return
    }
    destination.invoke()
    #expect(model.folders[id]?.pages.flatMap { page in page }.count == 4)
    #expect(model.undo())
    #expect(model.pages == original)
    #expect(model.folders[id]?.pages.flatMap { page in page }.count == 2)
}

@Test @MainActor func selectedAppsCanMoveToAnotherPageAndUndo() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let apps = (0..<60).map { index in record("App" + String(index), id: "id" + String(index)) }
    model.reconcile(with: apps)
    let original = model.pages
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.loadViewIfNeeded()
    guard original.count > 1,
          let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first,
          let collection = scroll.documentView as? GridCollectionView,
          let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
        Issue.record("grid unavailable"); return
    }
    collection.onItemMouseDown?(IndexPath(item: 0, section: 0), click)
    collection.onItemMouseDown?(IndexPath(item: 1, section: 0), click)
    guard let menu = collection.menuProvider?(IndexPath(item: 0, section: 0)),
          let destination = menu.items.first?.submenu?.items.dropFirst().first as? ClosureMenuItem else {
        Issue.record("page menu unavailable"); return
    }
    destination.invoke()
    #expect(!model.pages[0].contains(original[0][0]))
    #expect(!model.pages[0].contains(original[0][1]))
    #expect(model.undo())
    #expect(model.pages == original)
}

@Test @MainActor func refusedChangesAndCatalogChangesLeaveNothingToUndo() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let a = record("A", id: "a")
    model.reconcile(with: [a, record("B", id: "b")])

    model.moveItem(fromPage: 0, fromIndex: 0, toPage: 0, toIndex: 0)
    model.renameFolder(FolderID(value: "missing"), to: "X")
    #expect(!model.canUndo)

    model.hideApplication(a.id)
    #expect(model.canUndo)
    model.reconcile(with: [a, record("B", id: "b"), record("D", id: "d")])
    #expect(!model.canUndo)
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

@Test @MainActor func verticalLayoutModeSurvivesReloadWithoutChangingPages() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b")])
    let original = model.pages
    model.setLayoutMode(.verticalScroll)
    await model.save()
    let restored = makeModel(directory: dir)
    await restored.loadDocument()
    #expect(restored.layoutMode == .verticalScroll)
    #expect(restored.pages == original)
}

@Test @MainActor func verticalGridDisplaysAllPagesAndActivatesItems() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let apps = (0..<60).map { index in record("App" + String(index), id: "id" + String(index)) }
    model.reconcile(with: apps)
    let original = model.pages
    model.setLayoutMode(.verticalScroll)
    var launched: [StableAppID] = []
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { app in launched.append(app.id) }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView else { Issue.record("vertical grid unavailable"); return }
    #expect(collection.numberOfItems(inSection: 0) == 60)
    #expect(controller.currentCellSize == (collection.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize)
    collection.layoutSubtreeIfNeeded()
    #expect((collection.collectionViewLayout?.collectionViewContentSize.height ?? 0) > scroll.contentView.bounds.height)
    #expect(model.pages == original)
    #expect(controller.selectAllItems())
    #expect(collection.menuProvider?(IndexPath(item: 0, section: 0))?.items.first?.submenu != nil)
    controller.clearItemSelection()
    controller.moveSelection(deltaColumns: 0, deltaRows: 0)
    controller.launchSelection()
    #expect(launched == [apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }[0].id])
    model.setLayoutMode(.paged)
    #expect(model.pages == original)
}

@Test @MainActor func verticalKeyboardSelectionFollowsTheSameItemAfterReordering() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let apps = [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")]
    model.reconcile(with: apps)
    model.setLayoutMode(.verticalScroll)
    var launched: [StableAppID] = []
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { app in launched.append(app.id) }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    controller.moveSelection(deltaColumns: 0, deltaRows: 0)
    model.moveItem(fromPage: 0, fromIndex: 0, toPage: 0, toIndex: 2)
    controller.launchSelection()
    #expect(launched == [apps[0].id])
}

@Test @MainActor func verticalKeyboardNavigationScrollsToTheSelectedItem() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<105).map { index in record("App" + String(index), id: "id" + String(index)) })
    model.setLayoutMode(.verticalScroll)
    var launched: [StableAppID] = []
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { app in launched.append(app.id) }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }) else {
        Issue.record("vertical grid unavailable"); return
    }
    controller.moveSelection(deltaColumns: 0, deltaRows: 0)
    controller.moveSelection(deltaColumns: 0, deltaRows: 7)
    #expect(scroll.contentView.bounds.origin.y > 0)
    controller.launchSelection()
    guard case .app(let id) = model.pages.flatMap({ page in page })[49] else { Issue.record("expected app"); return }
    #expect(launched == [model.record(for: id)!.id])
}

@Test @MainActor func verticalSelectionDropsItemsRemovedFromTheCatalog() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let apps = [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")]
    model.reconcile(with: apps)
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    #expect(controller.selectAllItems())
    model.reconcile(with: Array(apps.prefix(2)))
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView,
          let menu = collection.menuProvider?(IndexPath(item: 0, section: 0)) else { Issue.record("vertical grid unavailable"); return }
    #expect(menu.items.count > 1)
}

@Test @MainActor func verticalGridViewportCanScrollThroughAllItems() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<105).map { index in record("App" + String(index), id: "id" + String(index)) })
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = controller.view
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView else { Issue.record("vertical grid unavailable"); return }
    #expect(collection.frame.height > scroll.contentView.bounds.height)
    let before = scroll.contentView.bounds.origin.y
    let visible = scroll.contentView.bounds
    collection.onMarqueePointer?(NSPoint(x: visible.midX, y: visible.maxY - 1))
    #expect(scroll.contentView.bounds.origin.y > before)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 250))
    scroll.reflectScrolledClipView(scroll.contentView)
    #expect(scroll.contentView.bounds.origin.y > before)
    controller.resetToFirstPage()
    #expect(scroll.contentView.bounds.origin.y == 0)
}

@Test @MainActor func verticalGridResizesAfterCatalogAndIconSettingsChange() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let apps = (0..<105).map { index in record("App" + String(index), id: "id" + String(index)) }
    model.reconcile(with: apps)
    var settings = model.gridSettings
    settings.iconScale = 0.7
    model.updateGridSettings(settings)
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView else { Issue.record("vertical grid unavailable"); return }
    let tall = collection.frame.height
    let smallScale = controller.currentIconLayoutMetrics.visualScale
    settings.iconScale = 1.0
    model.updateGridSettings(settings)
    #expect(controller.currentIconLayoutMetrics.visualScale > smallScale)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
    scroll.reflectScrolledClipView(scroll.contentView)
    #expect(scroll.contentView.bounds.origin.y > 0)
    model.reconcile(with: Array(apps.prefix(3)))
    controller.view.layoutSubtreeIfNeeded()
    #expect(scroll.contentView.bounds.origin.y == 0)
    #expect(collection.frame.height < tall)
    #expect(collection.frame.height >= scroll.contentView.bounds.height)
    #expect(collection.numberOfItems(inSection: 0) == 3)
}

@Test @MainActor func verticalGridAdaptsToViewportResizeWithoutChangingLayout() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<80).map { index in record("App" + String(index), id: "id" + String(index)) })
    let original = model.pages
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView,
          let flow = collection.collectionViewLayout as? NSCollectionViewFlowLayout else {
        Issue.record("vertical grid unavailable"); return
    }
    let before = flow.itemSize
    controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    controller.view.layoutSubtreeIfNeeded()
    #expect(flow.itemSize.width < before.width)
    #expect(flow.itemSize.height < before.height)
    #expect(collection.numberOfItems(inSection: 0) == 80)
    #expect(model.pages == original)
}

@Test @MainActor func verticalGridKeepsScrollPositionAfterSorting() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<105).map { index in record("App" + String(index), id: "id" + String(index)) })
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }) else {
        Issue.record("vertical grid unavailable"); return
    }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
    scroll.reflectScrolledClipView(scroll.contentView)
    let before = scroll.contentView.bounds.origin.y
    #expect(before > 0)
    model.applySortMode(.name)
    controller.view.layoutSubtreeIfNeeded()
    #expect(scroll.contentView.bounds.origin.y == before)
}

@Test @MainActor func switchingAwayFromVerticalCancelsAnActiveDrag() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<8).map { index in record("App" + String(index), id: "id" + String(index)) })
    let original = model.pages
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView,
          let first = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
          let target = collection.layoutAttributesForItem(at: IndexPath(item: 3, section: 0))?.frame else {
        Issue.record("vertical grid geometry unavailable"); return
    }
    func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: collection.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let start = NSPoint(x: first.midX, y: first.midY)
    let end = NSPoint(x: target.maxX - 2, y: target.midY)
    collection.onItemMouseDown?(IndexPath(item: 0, section: 0), event(.leftMouseDown, start))
    collection.onItemMouseDragged?(event(.leftMouseDragged, end))
    model.setLayoutMode(.paged)
    collection.onItemMouseUp?(event(.leftMouseUp, end))
    #expect(model.pages == original)
    #expect(!model.canUndo)
}

@MainActor
private final class WheelRecordingScrollView: NSScrollView {
    var wheelEvents = 0
    override func scrollWheel(with event: NSEvent) { wheelEvents += 1 }
}

@Test @MainActor func verticalWheelIsForwardedToTheScrollView() {
    let scroll = WheelRecordingScrollView()
    let collection = GridCollectionView()
    scroll.documentView = collection
    collection.scrollsVertically = true
    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -250, wheel2: 0, wheel3: 0),
          let event = NSEvent(cgEvent: cg) else { Issue.record("scroll event unavailable"); return }
    collection.scrollWheel(with: event)
    #expect(scroll.wheelEvents == 1)
}

@Test @MainActor func switchingFromVerticalKeepsTheVisiblePage() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<105).map { index in record("App" + String(index), id: "id" + String(index)) })
    let original = model.pages
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView,
          let target = collection.layoutAttributesForItem(at: IndexPath(item: 104, section: 0))?.frame,
          let control = controller.view.subviews.compactMap({ view in view as? PageControlView }).first else {
        Issue.record("vertical grid geometry unavailable"); return
    }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: target.minY))
    scroll.reflectScrolledClipView(scroll.contentView)
    guard let index = collection.collectionViewLayout?.layoutAttributesForElements(in: scroll.contentView.bounds).compactMap({ $0.indexPath?.item }).min() else {
        Issue.record("no visible item"); return
    }
    var offset = 0
    var expected = 0
    for (page, entries) in original.enumerated() {
        if index < offset + entries.count { expected = page; break }
        offset += entries.count
    }
    #expect(expected > 0)
    model.setLayoutMode(.paged)
    #expect(control.currentPage == expected)
    #expect(model.pages == original)
}

@Test @MainActor func switchingToVerticalCancelsPendingPageTransition() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<40).map { index in record("App" + String(index), id: "id" + String(index)) })
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let control = controller.view.subviews.compactMap({ view in view as? PageControlView }).first else {
        Issue.record("page control unavailable"); return
    }
    controller.moveSelection(deltaColumns: 0, deltaRows: 0)
    controller.moveSelection(deltaColumns: 0, deltaRows: 100)
    model.setLayoutMode(.verticalScroll)
    try await Task.sleep(for: .milliseconds(700))
    #expect(control.currentPage == 0)
    #expect(model.layoutMode == .verticalScroll)
}

@Test @MainActor func verticalGridDragReordersAndCanBeUndone() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<40).map { index in record("App" + String(index), id: "id" + String(index)) })
    let original = model.pages
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView,
          let source = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
          let target = collection.layoutAttributesForItem(at: IndexPath(item: 3, section: 0))?.frame else {
        Issue.record("vertical grid geometry unavailable"); return
    }
    func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: collection.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let start = NSPoint(x: source.midX, y: source.midY)
    let end = NSPoint(x: target.maxX - 2, y: target.midY)
    collection.onItemMouseDown?(IndexPath(item: 0, section: 0), event(.leftMouseDown, start))
    collection.onItemMouseDragged?(event(.leftMouseDragged, end))
    collection.onItemMouseUp?(event(.leftMouseUp, end))
    #expect(Array(model.pages[0].prefix(4)) == [original[0][1], original[0][2], original[0][3], original[0][0]])
    #expect(model.undo())
    #expect(model.pages == original)
}

@Test @MainActor func verticalGroupDragPreservesOrderAndCanBeUndone() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<8).map { index in record("App" + String(index), id: "id" + String(index)) })
    let original = model.pages
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView,
          let first = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
          let second = collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame,
          let target = collection.layoutAttributesForItem(at: IndexPath(item: 3, section: 0))?.frame else {
        Issue.record("vertical grid geometry unavailable"); return
    }
    func event(_ type: NSEvent.EventType, _ point: NSPoint, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: collection.convert(point, to: nil), modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    for (index, frame) in [(0, first), (1, second)] {
        let point = NSPoint(x: frame.midX, y: frame.midY)
        collection.onItemMouseDown?(IndexPath(item: index, section: 0), event(.leftMouseDown, point, .command))
    }
    let start = NSPoint(x: first.midX, y: first.midY)
    let end = NSPoint(x: target.maxX - 2, y: target.midY)
    collection.onItemMouseDown?(IndexPath(item: 0, section: 0), event(.leftMouseDown, start))
    collection.onItemMouseDragged?(event(.leftMouseDragged, end))
    collection.onItemMouseUp?(event(.leftMouseUp, end))
    #expect(Array(model.pages[0].prefix(4)) == [original[0][2], original[0][3], original[0][0], original[0][1]])
    #expect(model.undo())
    #expect(model.pages == original)
}

@Test @MainActor func verticalGroupDropCreatesFolderWithAllSelectedApps() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<8).map { index in record("App" + String(index), id: "id" + String(index)) })
    let original = model.pages
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView,
          let first = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
          let second = collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame,
          let target = collection.layoutAttributesForItem(at: IndexPath(item: 3, section: 0))?.frame else {
        Issue.record("vertical grid geometry unavailable"); return
    }
    func event(_ type: NSEvent.EventType, _ point: NSPoint, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: collection.convert(point, to: nil), modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    for (index, frame) in [(0, first), (1, second)] {
        collection.onItemMouseDown?(IndexPath(item: index, section: 0), event(.leftMouseDown, NSPoint(x: frame.midX, y: frame.midY), .command))
    }
    let start = NSPoint(x: first.midX, y: first.midY)
    let end = NSPoint(x: target.midX, y: target.midY)
    collection.onItemMouseDown?(IndexPath(item: 0, section: 0), event(.leftMouseDown, start))
    collection.onItemMouseDragged?(event(.leftMouseDragged, end))
    collection.onItemMouseUp?(event(.leftMouseUp, end))
    guard let folder = model.folders.values.first else { Issue.record("folder missing"); return }
    #expect(folder.pages.flatMap { page in page } == [original[0][3], original[0][0], original[0][1]])
    #expect(model.undo())
    #expect(model.pages == original)
}

@Test @MainActor func verticalDragIntoGapUsesTheNearestInsertion() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<8).map { index in record("App" + String(index), id: "id" + String(index)) })
    let original = model.pages
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView,
          let source = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
          let target = collection.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))?.frame,
          let next = collection.layoutAttributesForItem(at: IndexPath(item: 3, section: 0))?.frame else {
        Issue.record("vertical grid geometry unavailable"); return
    }
    func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: collection.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let start = NSPoint(x: source.midX, y: source.midY)
    let end = NSPoint(x: target.maxX + min(3, (next.minX - target.maxX) / 4), y: target.midY)
    collection.onItemMouseDown?(IndexPath(item: 0, section: 0), event(.leftMouseDown, start))
    collection.onItemMouseDragged?(event(.leftMouseDragged, end))
    collection.onItemMouseUp?(event(.leftMouseUp, end))
    #expect(Array(model.pages[0].prefix(3)) == [original[0][1], original[0][2], original[0][0]])
    #expect(model.undo())
    #expect(model.pages == original)
}

@Test @MainActor func verticalDragOntoAppCreatesFolderAndCanBeUndone() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")])
    let original = model.pages
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView,
          let source = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
          let target = collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame else {
        Issue.record("vertical grid geometry unavailable"); return
    }
    func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: collection.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let start = NSPoint(x: source.midX, y: source.midY)
    let end = NSPoint(x: target.midX, y: target.midY)
    collection.onItemMouseDown?(IndexPath(item: 0, section: 0), event(.leftMouseDown, start))
    collection.onItemMouseDragged?(event(.leftMouseDragged, end))
    collection.onItemMouseUp?(event(.leftMouseUp, end))
    #expect(model.folders.count == 1)
    #expect(model.undo())
    #expect(model.pages == original)
}

@Test @MainActor func verticalDragCanMoveAcrossSavedPages() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<40).map { index in record("App" + String(index), id: "id" + String(index)) })
    let original = model.pages
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView,
          let source = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
          let target = collection.layoutAttributesForItem(at: IndexPath(item: 37, section: 0))?.frame else {
        Issue.record("vertical grid geometry unavailable"); return
    }
    func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: collection.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let start = NSPoint(x: source.midX, y: source.midY)
    collection.onItemMouseDown?(IndexPath(item: 0, section: 0), event(.leftMouseDown, start))
    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, target.midY - 200)))
    scroll.reflectScrolledClipView(scroll.contentView)
    let end = NSPoint(x: target.maxX - 2, y: target.midY)
    collection.onItemMouseDragged?(event(.leftMouseDragged, end))
    collection.onItemMouseUp?(event(.leftMouseUp, end))
    #expect(model.pages[1].contains(original[0][0]))
    #expect(model.undo())
    #expect(model.pages == original)
}

@Test @MainActor func verticalGroupDragCombinesItemsFromDifferentPages() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<75).map { index in record("App" + String(index), id: "id" + String(index)) })
    let original = model.pages
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView,
          let source = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
          let target = collection.layoutAttributesForItem(at: IndexPath(item: 72, section: 0))?.frame else {
        Issue.record("vertical grid geometry unavailable"); return
    }
    func event(_ type: NSEvent.EventType, _ point: NSPoint, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: collection.convert(point, to: nil), modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let start = NSPoint(x: source.midX, y: source.midY)
    collection.onItemMouseDown?(IndexPath(item: 0, section: 0), event(.leftMouseDown, start, .command))
    collection.onItemMouseDown?(IndexPath(item: 37, section: 0), event(.leftMouseDown, start, .command))
    collection.onItemMouseDown?(IndexPath(item: 0, section: 0), event(.leftMouseDown, start))
    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, target.midY - 200)))
    scroll.reflectScrolledClipView(scroll.contentView)
    let end = NSPoint(x: target.maxX - 2, y: target.midY)
    collection.onItemMouseDragged?(event(.leftMouseDragged, end))
    collection.onItemMouseUp?(event(.leftMouseUp, end))
    guard let first = model.pages[2].firstIndex(of: original[0][0]),
          let second = model.pages[2].firstIndex(of: original[1][2]) else { Issue.record("group did not reach destination"); return }
    #expect(second == first + 1)
    #expect(model.undo())
    #expect(model.pages == original)
}

@Test @MainActor func verticalMarqueeSelectsWithoutClosing() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")])
    model.setLayoutMode(.verticalScroll)
    var dismissed = 0
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: { dismissed += 1 })
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView,
          let second = collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame else {
        Issue.record("vertical grid geometry unavailable"); return
    }
    func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: collection.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let start = NSPoint(x: 1, y: 1)
    let end = NSPoint(x: second.maxX, y: second.maxY)
    collection.mouseDown(with: event(.leftMouseDown, start))
    collection.mouseDragged(with: event(.leftMouseDragged, end))
    #expect(collection.isMarqueeActive)
    collection.mouseUp(with: event(.leftMouseUp, end))
    #expect(!collection.isMarqueeActive)
    #expect(dismissed == 0)
    #expect(collection.menuProvider?(IndexPath(item: 0, section: 0))?.items.first?.submenu != nil)
}

@Test @MainActor func verticalDragReleasedOutsideDoesNotChangeLayout() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: (0..<40).map { index in record("App" + String(index), id: "id" + String(index)) })
    let original = model.pages
    model.setLayoutMode(.verticalScroll)
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    guard let scroll = controller.view.subviews.compactMap({ view in view as? NSScrollView }).first(where: { !$0.isHidden }),
          let collection = scroll.documentView as? GridCollectionView,
          let source = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame else {
        Issue.record("vertical grid geometry unavailable"); return
    }
    func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: collection.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let start = NSPoint(x: source.midX, y: source.midY)
    let end = NSPoint(x: scroll.contentView.bounds.maxX + 200, y: scroll.contentView.bounds.maxY + 200)
    collection.onItemMouseDown?(IndexPath(item: 0, section: 0), event(.leftMouseDown, start))
    collection.onItemMouseDragged?(event(.leftMouseDragged, end))
    collection.onItemMouseUp?(event(.leftMouseUp, end))
    #expect(model.pages == original)
    #expect(!model.canUndo)
}

@Test @MainActor func layoutBackupRestoresTheGridWithoutChangingPreferences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = makeModel(directory: root.appendingPathComponent("source"))
    let target = makeModel(directory: root.appendingPathComponent("target"))
    await source.loadDocument()
    await target.loadDocument()
    let apps = [record("Alpha", id: "a"), record("Beta", id: "b")]
    source.reconcile(with: apps)
    source.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    var settings = source.gridSettings
    settings.columns = 5
    source.updateGridSettings(settings)
    let url = root.appendingPathComponent("backup.json")
    try await source.exportLayoutBackup(to: url)

    target.reconcile(with: apps)
    target.setShowsMenuBarIcon(false)
    target.setReturnToFirstPage(true)
    target.setCloseOnBackgroundClick(false)
    target.setScreenTarget(.main)
    let previousPages = target.pages
    try await target.restoreLayoutBackup(from: url)
    #expect(target.pages == source.pages)
    #expect(target.folders == source.folders)
    #expect(target.gridSettings.columns == 5)
    #expect(!target.showsMenuBarIcon)
    #expect(target.returnToFirstPage)
    #expect(!target.closeOnBackgroundClick)
    #expect(target.screenTarget == .main)
    let backupURL = root.appendingPathComponent("target/layout.lastknowngood.json")
    let previous = try JSONDecoder().decode(LayoutDocument.self, from: Data(contentsOf: backupURL))
    #expect(previous.pages == previousPages)

    let persisted = makeModel(directory: root.appendingPathComponent("target"))
    await persisted.loadDocument()
    #expect(persisted.pages == source.pages)
    #expect(persisted.folders == source.folders)
    #expect(!persisted.showsMenuBarIcon)
    #expect(persisted.returnToFirstPage)
    #expect(!persisted.closeOnBackgroundClick)
    #expect(persisted.screenTarget == .main)
}

@Test @MainActor func invalidLayoutBackupDoesNotReplaceTheExistingLayout() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeModel(directory: root)
    await model.loadDocument()
    let app = record("Alpha", id: "a")
    model.reconcile(with: [app])
    _ = await model.save()
    let original = model.pages
    var invalid = LayoutDocument.empty
    invalid.pages = [[.app(app.id.asPersistenceIdentifier), .app(app.id.asPersistenceIdentifier)]]
    let url = root.appendingPathComponent("invalid.json")
    try JSONEncoder().encode(invalid).write(to: url)
    do {
        try await model.restoreLayoutBackup(from: url)
        Issue.record("invalid backup was accepted")
    } catch LayoutBackupError.invalidFormat {
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(model.pages == original)
    let reloaded = makeModel(directory: root)
    await reloaded.loadDocument()
    #expect(reloaded.pages == original)
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

@Test @MainActor func sortDirectionReversesOrderAndPersists() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    let apps = [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")]
    model.reconcile(with: apps)
    model.applySortMode(.name)
    let ascending = model.pages
    model.setSortReversed(true)
    #expect(model.pages[0] == Array(ascending[0].reversed()))
    await model.save()
    let restored = makeModel(directory: dir)
    await restored.loadDocument()
    #expect(restored.gridSettings.sortReversed)
    #expect(restored.pages == model.pages)
    model.setSortReversed(false)
    #expect(model.pages == ascending)
}

@Test func usageReaderCountsOnlyApplicationEventsAndReportsErrors() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: ApplicationUsageReader.ReadError.self) { try ApplicationUsageReader.read(from: url) }
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { Issue.record("fixture open failed"); return }
    let sql = "CREATE TABLE ZOBJECT (ZVALUESTRING TEXT, ZSTREAMNAME TEXT); INSERT INTO ZOBJECT VALUES ('a', '/app/usage'), ('a', '/app/usage'), ('b', '/app/usage'), ('a', '/other'), (NULL, '/app/usage');"
    let status = sqlite3_exec(db, sql, nil, nil, nil)
    sqlite3_close(db)
    #expect(status == SQLITE_OK)
    #expect(try ApplicationUsageReader.read(from: url) == ["a": 2, "b": 1])
}

@Test @MainActor func usageSortUsesCountsAndPreservesLayoutOnReadError() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("usage.db")
    let model = makeModel(directory: dir.appendingPathComponent("layout"))
    await model.loadDocument()
    let apps = [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")]
    model.reconcile(with: apps)
    let before = model.pages
    let revision = model.sortRevision
    do {
        try await model.sortByUsage(from: url)
        Issue.record("expected a read error")
    } catch { }
    #expect(model.pages == before)
    #expect(model.sortRevision != revision)
    #expect(model.gridSettings.sortMode == .custom)
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { Issue.record("fixture open failed"); return }
    let sql = "CREATE TABLE ZOBJECT (ZVALUESTRING TEXT, ZSTREAMNAME TEXT); INSERT INTO ZOBJECT VALUES ('b', '/app/usage'), ('b', '/app/usage'), ('c', '/app/usage');"
    let status = sqlite3_exec(db, sql, nil, nil, nil)
    sqlite3_close(db)
    #expect(status == SQLITE_OK)
    try await model.sortByUsage(from: url)
    #expect(model.pages[0] == [apps[1], apps[2], apps[0]].map { app in .app(app.id.asPersistenceIdentifier) })
    await model.save()
    let restored = makeModel(directory: dir.appendingPathComponent("layout"))
    await restored.loadDocument()
    #expect(restored.gridSettings.sortMode == .usage)
    #expect(!restored.canAdjustUsageSort)
    restored.setSortReversed(true)
    #expect(!restored.gridSettings.sortReversed)
    model.setSortReversed(true)
    #expect(model.pages[0] == [apps[0], apps[2], apps[1]].map { app in .app(app.id.asPersistenceIdentifier) })
}

@Test @MainActor func folderSortingCanBeDisabledAndRestored() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")])
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    guard let id = model.folders.keys.first else { Issue.record("folder missing"); return }
    let original = model.folders[id]?.pages
    model.setSortFolders(false)
    model.applySortMode(.name)
    #expect(model.folders[id]?.pages == original)
    await model.save()
    let restored = makeModel(directory: dir)
    await restored.loadDocument()
    #expect(!restored.gridSettings.sortFolders)
    model.setSortFolders(true)
    #expect(model.folders[id]?.pages.first == original?.first.map { page in Array(page.reversed()) })
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

    // The layout has to name the records by their real identifiers. With made-up
    // ones nothing matches, every app is stamped as new with `Date()`, and in a
    // release build three stamps taken back to back can be equal, so the sort
    // below depended on timing instead of on the backfill.
    let records = [record("Apple", id: "a"), record("Banana", id: "b"), record("Cherry", id: "c")]
    var document = LayoutDocument.empty
    document.pages = [records.map { LayoutItem.app($0.id.asPersistenceIdentifier) }]
    #expect(document.dateAddedByID.isEmpty, "sanity check: no dateAdded metadata exists yet")
    try await store.save(document)

    let model = GridModel(layoutStore: store)
    await model.loadDocument()
    // None of these are "new" (all already placed) — this exercises only
    // the backfill path, not the genuinely-new-record stamping path.
    model.reconcile(with: records)

    model.applySortMode(.dateAdded)
    let order = model.pages[0].compactMap { item -> String? in
        if case .app(let id) = item { return model.record(for: id)?.displayName }
        return nil
    }
    #expect(order == ["Cherry", "Banana", "Apple"])
}

@Test @MainActor func backfillFindsMissingDatesInsideFoldersAndKeepsExistingValues() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)
    let apps = [record("Alpha", id: "a"), record("Beta", id: "b"), record("Gamma", id: "c")]
    let ids = apps.map { $0.id.asPersistenceIdentifier }
    let folder = Folder(name: "Folder", pages: [[.app(ids[1]), .app(ids[2])]])
    var document = LayoutDocument.empty
    document.pages = [[.app(ids[0]), .folder(folder.id)]]
    document.folders = [folder.id: folder]
    document.dateAddedByID[ids[0]] = Date(timeIntervalSince1970: 111)
    document.dateAddedByID[ids[2]] = Date(timeIntervalSince1970: 222)
    try await store.save(document)
    let model = GridModel(layoutStore: store)
    await model.loadDocument()
    _ = model.reconcile(with: apps)
    #expect(await model.save())
    let result = await store.load()
    #expect(result.dateAddedByID[ids[0]] == Date(timeIntervalSince1970: 111))
    #expect(result.dateAddedByID[ids[1]] == Date(timeIntervalSince1970: 0))
    #expect(result.dateAddedByID[ids[2]] == Date(timeIntervalSince1970: 222))
    #expect(!model.reconcile(with: apps))
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
