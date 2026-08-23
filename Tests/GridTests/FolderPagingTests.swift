import AppKit
import Catalog
import Foundation
import Persistence
import Testing
@testable import Grid

private func pagingRecord(_ name: String) -> ApplicationRecord {
    ApplicationRecord(
        id: StableAppID(bundleURL: URL(fileURLWithPath: "/tmp/\(name).app"), bundleIdentifier: name, teamIdentifier: nil),
        bundleIdentifier: name,
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
        isMenuBarApp: false,
        iconCacheKey: name,
        canLaunch: true,
        canOpenNewInstance: true,
        lastSeenModificationDate: Date(timeIntervalSince1970: 0)
    )
}

/// Builds a model whose single folder holds `count` apps, packed by the
/// model's own rules.
@MainActor
private func modelWithFolder(itemCount count: Int, directory: URL) async -> (GridModel, FolderID) {
    let model = GridModel(layoutStore: LayoutStore(directory: directory))
    await model.loadDocument()
    let records = (1...count).map { pagingRecord("app\($0)") }
    model.reconcile(with: records)
    // Drop the first app onto the second to make a folder, then drop each
    // remaining app onto that folder.
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    while model.pages[0].count > 1 {
        model.createOrJoinFolder(sourcePage: 0, sourceIndex: 1, destinationPage: 0, destinationIndex: 0)
    }
    guard case .folder(let id) = model.pages[0][0] else {
        Issue.record("expected a folder")
        return (model, FolderID())
    }
    return (model, id)
}

@MainActor
private func makePanel(model: GridModel, folderID: FolderID, columns: Int = 3) -> FolderContentsViewController {
    let panel = FolderContentsViewController(
        model: model,
        folderID: folderID,
        iconCache: IconCache(),
        iconSize: 96,
        columns: columns,
        panelWidth: 600,
        maximumHeight: 800,
        onLaunch: { _ in },
        onItemDraggedOut: { _, _ in }
    )
    panel.loadViewIfNeeded()
    return panel
}

/// A folder holding more than one page shows exactly one of them at a time —
/// the whole point of moving off the single flattened scrolling list.
@Test @MainActor func aMultiPageFolderShowsOnePageAtATime() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (model, folderID) = await modelWithFolder(itemCount: 14, directory: dir)

    #expect(model.folders[folderID]?.pages.map(\.count) == [9, 5])

    let panel = makePanel(model: model, folderID: folderID)
    #expect(panel.pageCountForTesting == 2)
    #expect(panel.currentPageForTesting == 0)
    #expect(panel.visibleTileCountForTesting == 9)
}

/// A folder that fits on one page must not offer paging at all.
@Test @MainActor func aSinglePageFolderHasNoPaging() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (model, folderID) = await modelWithFolder(itemCount: 5, directory: dir)

    let panel = makePanel(model: model, folderID: folderID)
    #expect(panel.pageCountForTesting == 1)
    #expect(panel.visibleTileCountForTesting == 5)
    // Arrow keys have nothing to do, so they must fall through rather than
    // silently swallowing the key.
    #expect(panel.handleArrowKey(delta: 1) == false)
}

@Test @MainActor func arrowKeysPageAMultiPageFolder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (model, folderID) = await modelWithFolder(itemCount: 14, directory: dir)
    let panel = makePanel(model: model, folderID: folderID)

    #expect(panel.handleArrowKey(delta: 1) == true)
    #expect(panel.currentPageForTesting == 1)
    // Already on the last page: the index must not run past the end.
    _ = panel.handleArrowKey(delta: 1)
    #expect(panel.currentPageForTesting == 1)

    _ = panel.handleArrowKey(delta: -1)
    #expect(panel.currentPageForTesting == 0)
    _ = panel.handleArrowKey(delta: -1)
    #expect(panel.currentPageForTesting == 0)
}

/// The card is sized from the fullest page, so paging onto a half-empty last
/// page must not resize it under the cursor.
@Test @MainActor func theCardKeepsItsSizeAcrossPages() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (model, folderID) = await modelWithFolder(itemCount: 14, directory: dir)
    let panel = makePanel(model: model, folderID: folderID)

    let sizeOnFirstPage = panel.preferredContentSize
    _ = panel.handleArrowKey(delta: 1)
    #expect(panel.preferredContentSize == sizeOnFirstPage)
}

/// The index moving is not the point — the tiles actually swapping is. The
/// page change runs through a slide/fade whose completion handler does the
/// rebuild, so this waits for that rather than asserting synchronously.
@Test @MainActor func pagingSwapsTheVisibleTiles() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (model, folderID) = await modelWithFolder(itemCount: 14, directory: dir)
    let panel = makePanel(model: model, folderID: folderID)
    #expect(panel.visibleTileCountForTesting == 9)

    // Polled rather than slept on a fixed delay: the rebuild happens in the
    // page animation's completion handler, and a flat wait fails the moment the
    // machine is busy — this test did exactly that once other tests started
    // rendering real windows alongside it.
    _ = panel.handleArrowKey(delta: 1)
    for _ in 0..<60 where panel.visibleTileCountForTesting != 5 {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(panel.currentPageForTesting == 1)
    #expect(panel.visibleTileCountForTesting == 5)

    _ = panel.handleArrowKey(delta: -1)
    for _ in 0..<60 where panel.visibleTileCountForTesting != 9 {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(panel.visibleTileCountForTesting == 9)
}

// MARK: - Renaming in place

@Test @MainActor func editingTheTitleRenamesTheFolder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (model, folderID) = await modelWithFolder(itemCount: 4, directory: dir)
    let panel = makePanel(model: model, folderID: folderID)

    panel.titleForTesting = "  Games  "
    panel.commitTitleEdit()
    #expect(model.folders[folderID]?.name == "Games")
}

/// Clearing the field is not a rename — a folder with no name at all would be
/// unidentifiable on the grid, so the old one comes back.
@Test @MainActor func clearingTheTitleRestoresTheExistingName() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (model, folderID) = await modelWithFolder(itemCount: 4, directory: dir)
    model.renameFolder(folderID, to: "Utilities")
    let panel = makePanel(model: model, folderID: folderID)

    panel.titleForTesting = "   "
    panel.commitTitleEdit()
    #expect(model.folders[folderID]?.name == "Utilities")
    #expect(panel.titleForTesting == "Utilities")
}

// MARK: - Swiping between folder pages

@MainActor
private func swipe(_ panel: FolderContentsViewController, dx: Double) {
    let root = panel.view
    for (deltaX, phase) in [(0.0, CGScrollPhase.began), (dx, .changed), (0.0, .ended)] {
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { continue }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: deltaX)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        if let event = NSEvent(cgEvent: cg) {
            root.scrollWheel(with: event)
        }
    }
}

/// The folder pages by the same gesture as the grid behind it.
@Test @MainActor func swipingPagesTheFolder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (model, folderID) = await modelWithFolder(itemCount: 14, directory: dir)
    let panel = makePanel(model: model, folderID: folderID)

    // Leftward travel means "next page", matching the grid's own direction.
    swipe(panel, dx: -60)
    #expect(panel.currentPageForTesting == 1)

    swipe(panel, dx: 60)
    #expect(panel.currentPageForTesting == 0)
}

/// Below the commit distance it must stay put — otherwise resting fingers page
/// the folder out from under the user.
@Test @MainActor func aSwipeShorterThanTheCommitDistanceDoesNotPage() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (model, folderID) = await modelWithFolder(itemCount: 14, directory: dir)
    let panel = makePanel(model: model, folderID: folderID)

    // Past the 10pt engage gate but short of the 20pt commit distance.
    swipe(panel, dx: -14)
    #expect(panel.currentPageForTesting == 0)
}

/// A one-page folder has nowhere to go, and must not move regardless.
@Test @MainActor func swipingASinglePageFolderDoesNothing() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (model, folderID) = await modelWithFolder(itemCount: 5, directory: dir)
    let panel = makePanel(model: model, folderID: folderID)

    swipe(panel, dx: -80)
    #expect(panel.currentPageForTesting == 0)
    #expect(panel.visibleTileCountForTesting == 5)
}
