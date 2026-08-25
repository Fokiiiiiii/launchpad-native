import AppKit
import Catalog
import Foundation
import Persistence
import Testing
@testable import Grid

/// Exercises the real grid in a real window: build it, let its icons load, and
/// look at what came out.
///
/// `GridViewController` is the largest thing in this project and had no test of
/// its own rendering. Everything about it — cell reuse, icon fetches racing
/// reloads, the icon size settling after the first layout pass — has produced
/// user-visible bugs, and each was found by running the app and looking.
private func gridRecord(_ name: String) -> ApplicationRecord {
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

@MainActor
private final class GridHarness {
    let window: NSWindow
    let controller: GridViewController
    let model: GridModel
    private(set) var launched: [String] = []
    private(set) var backgroundClicks = 0

    init(appCount: Int, directory: URL, size: NSSize = NSSize(width: 1_680, height: 1_050)) async {
        model = GridModel(layoutStore: LayoutStore(directory: directory))
        await model.loadDocument()
        model.reconcile(with: (1...appCount).map { gridRecord("app\($0)") })

        var launchedNames: [String] = []
        var clicks = 0
        controller = GridViewController(
            model: model,
            iconCache: IconCache(),
            onLaunch: { launchedNames.append($0.bundleIdentifier) },
            onBackgroundClick: { clicks += 1 }
        )
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // See `FolderOverlayPresentationTests`: a programmatic window frees
        // itself on close, and several tests closing their own crashed the run.
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.view.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        controller.reload()
        controller.view.layoutSubtreeIfNeeded()
        recordLaunches = { launchedNames }
        recordClicks = { clicks }
    }

    private var recordLaunches: () -> [String] = { [] }
    private var recordClicks: () -> Int = { 0 }
    var launchedApps: [String] { recordLaunches() }
    var clickCount: Int { recordClicks() }

    /// Waits until every visible cell has a real icon, or gives up.
    func waitForIcons(_ expected: Int) async throws {
        for _ in 0..<40 {
            controller.view.layoutSubtreeIfNeeded()
            if drawnIconCount() >= expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Counts cells whose icon region actually drew something picture-like.
    func drawnIconCount() -> Int {
        guard let bitmap = RenderProbe.render(controller.view) else { return 0 }
        var drawn = 0
        for cell in visibleCells() {
            let frame = cell.view.convert(cell.iconFrame, to: controller.view)
            if RenderProbe.colorVariation(bitmap, in: frame) > 0.08 { drawn += 1 }
        }
        return drawn
    }

    /// The cell for one slot on the current page, by index rather than by
    /// position — `visibleItems()` comes back in no particular order.
    func cell(at index: Int) -> GridCellItem? {
        guard let collectionView = controller.view.subviews
            .compactMap({ $0 as? NSScrollView }).first?.documentView as? NSCollectionView
        else { return nil }
        return collectionView.item(at: IndexPath(item: index, section: 0)) as? GridCellItem
    }

    func visibleCells() -> [GridCellItem] {
        guard let collectionView = controller.view.subviews
            .compactMap({ $0 as? NSScrollView }).first?.documentView as? NSCollectionView
        else { return [] }
        return collectionView.visibleItems().compactMap { $0 as? GridCellItem }
    }

    func teardown() { window.orderOut(nil) }
}

/// The grid draws its apps: real icons, not empty boxes.
@Test @MainActor func theGridDrawsItsIcons() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let harness = await GridHarness(appCount: 12, directory: dir)
    defer { harness.teardown() }

    #expect(!harness.visibleCells().isEmpty, "the grid produced no cells at all")
    try await harness.waitForIcons(harness.visibleCells().count)
    #expect(harness.drawnIconCount() == harness.visibleCells().count, "some cells never drew an icon")
}

/// Icon size is decided per cell when it is built, and nothing revisits it — so
/// a cell built before the grid's layout settled keeps the pre-settle size.
///
/// This is the "icons are briefly large on first launch, then shrink" bug, and
/// reproducing it needs the layout to actually change *after* the cells exist:
/// on a cold start the first pass runs before the Dock has been measured, and
/// the cells built there are sized against a taller cell than the grid ends up
/// with. Resizing the view here stands in for that.
@Test @MainActor func cellsFollowTheIconSizeWhenTheLayoutChangesUnderThem() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let harness = await GridHarness(appCount: 12, directory: dir, size: NSSize(width: 1_680, height: 1_050))
    defer { harness.teardown() }
    try await harness.waitForIcons(1)

    let sizeBefore = harness.controller.currentIconLayoutMetrics.baseSize * harness.controller.currentIconLayoutMetrics.visualScale

    // Shrink the grid the way settling the bottom inset does, without rebuilding
    // any cells: exactly the situation the real bug happens in.
    harness.controller.view.frame = NSRect(x: 0, y: 0, width: 1_680, height: 780)
    harness.controller.view.layoutSubtreeIfNeeded()

    let sizeAfter = harness.controller.currentIconLayoutMetrics.baseSize * harness.controller.currentIconLayoutMetrics.visualScale
    #expect(sizeAfter < sizeBefore, "the test did not actually change the layout")

    for cell in harness.visibleCells() {
        let drawn = cell.iconFrame.width
        #expect(abs(drawn - sizeAfter) < 1.0, "cell still drawn at \(drawn)pt after the grid moved to \(sizeAfter)pt")
    }
}

/// Cells are recycled across reloads, and an icon fetch that outlives its cell
/// used to be applied over whatever now occupied it. Reloading repeatedly with
/// different contents must not leave a cell showing the wrong app.
@Test @MainActor func reloadingRepeatedlyLeavesEveryCellConsistent() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let harness = await GridHarness(appCount: 12, directory: dir)
    defer { harness.teardown() }

    for round in 1...5 {
        harness.model.reconcile(with: (1...(6 + round)).map { gridRecord("app\($0)") })
        harness.controller.reload()
        harness.controller.view.layoutSubtreeIfNeeded()
    }
    try await harness.waitForIcons(harness.visibleCells().count)

    let cells = harness.visibleCells()
    #expect(!cells.isEmpty)
    #expect(harness.drawnIconCount() == cells.count, "a recycled cell was left without an icon")
}

// MARK: - Page snapshot cache

/// Rendering a neighbour page costs 320-375ms of blocked main thread — it
/// builds a throwaway collection view, every cell in it, and draws the result.
/// That ran on every swipe, which made paging quickly unusable. The same page
/// renders identically until the model changes, so it is cached.
@Test @MainActor func aPageSnapshotIsRenderedOnceAndReused() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    // Enough apps for several pages.
    let harness = await GridHarness(appCount: 60, directory: dir)
    defer { harness.teardown() }
    try await harness.waitForIcons(1)

    let size = NSSize(width: 800, height: 600)
    let first = harness.controller.pageSnapshotForTesting(page: 1, size: size)
    #expect(first != nil, "the grid should have a second page to snapshot")

    let second = harness.controller.pageSnapshotForTesting(page: 1, size: size)
    // Identity, not equality: a cache hit returns the very same image.
    #expect(first === second, "the second request re-rendered instead of reusing")
}

/// A page whose icons have not loaded yet renders with gaps. Keeping that
/// picture meant every later swipe onto the page showed the same gaps, and the
/// icons only reappeared when the live grid took over at the end of the drag —
/// an icon that blinks out for the length of a swipe, on that page only,
/// forever after the one unlucky swipe that cached it.
@Test @MainActor func anIncompleteSnapshotIsNotKept() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let harness = await GridHarness(appCount: 60, directory: dir)
    defer { harness.teardown() }
    // Deliberately no `waitForIcons`: the icons are still loading, which is
    // exactly the state a swipe can catch a neighbouring page in.

    let size = NSSize(width: 800, height: 600)
    let first = harness.controller.pageSnapshotForTesting(page: 1, size: size)
    let second = harness.controller.pageSnapshotForTesting(page: 1, size: size)
    #expect(first !== second, "a snapshot drawn with missing icons was cached")

    // Once everything is warm the same request does get cached.
    try await harness.waitForIcons(1)
    let warm = harness.controller.pageSnapshotForTesting(page: 1, size: size)
    let warmAgain = harness.controller.pageSnapshotForTesting(page: 1, size: size)
    #expect(warm === warmAgain, "a complete snapshot was re-rendered instead of reused")
}

/// A cached snapshot must not outlive the arrangement it depicts.
@Test @MainActor func changingTheModelInvalidatesCachedSnapshots() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let harness = await GridHarness(appCount: 60, directory: dir)
    defer { harness.teardown() }
    try await harness.waitForIcons(1)

    let size = NSSize(width: 800, height: 600)
    let before = harness.controller.pageSnapshotForTesting(page: 1, size: size)
    harness.controller.reload()
    let after = harness.controller.pageSnapshotForTesting(page: 1, size: size)
    #expect(before !== after, "a stale snapshot survived a model change")
}

/// A different size is a different picture, so it cannot reuse the entry.
@Test @MainActor func aDifferentSizeRendersItsOwnSnapshot() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let harness = await GridHarness(appCount: 60, directory: dir)
    defer { harness.teardown() }
    try await harness.waitForIcons(1)

    let small = harness.controller.pageSnapshotForTesting(page: 1, size: NSSize(width: 800, height: 600))
    let large = harness.controller.pageSnapshotForTesting(page: 1, size: NSSize(width: 1_000, height: 700))
    #expect(small !== large)
}

// MARK: - Keyboard selection

/// The arrow keys are the only way to reach an icon without a pointer, and the
/// selection they move has to be visible. It was not: `select` asked for a
/// `reloadItems`, which `NSCollectionView` batches, so the highlight did not
/// appear until something else happened to rebuild the page. Painting the live
/// cell is also what the drag machinery had to switch to, for the same class
/// of reason.
@Test @MainActor func arrowKeySelectionPaintsTheCellImmediately() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let harness = await GridHarness(appCount: 14, directory: dir)
    defer { harness.teardown() }
    try await harness.waitForIcons(1)

    let before = try #require(RenderProbe.render(harness.controller.view))
    let target = try #require(harness.cell(at: 4))

    harness.controller.moveSelection(deltaColumns: 0, deltaRows: 0)
    harness.controller.moveSelection(deltaColumns: 4, deltaRows: 0)
    let after = try #require(RenderProbe.render(harness.controller.view))

    // Sample inside the tile but outside the icon artwork: an app icon leaves
    // a margin inside its own image, so the tile shows through there.
    let iconFrame = target.view.convert(target.iconFrame, to: harness.controller.view)
    let probe = NSPoint(x: iconFrame.minX + 3, y: iconFrame.midY)
    #expect(
        RenderProbe.coverage(after, in: NSRect(x: probe.x - 2, y: probe.y - 2, width: 4, height: 4)) > 0.9,
        "nothing was drawn beside the selected icon"
    )
    #expect(
        RenderProbe.coverage(before, in: NSRect(x: probe.x - 2, y: probe.y - 2, width: 4, height: 4)) < 0.1,
        "something was already drawn there before anything was selected"
    )
}

/// The tile hugs the icon rather than the icon *and* its label: it should read
/// as the icon sitting on a tile, and a band wide enough to hold a long name
/// reads as a text selection instead.
@Test @MainActor func theSelectionTileIsASquareAroundTheIconAlone() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let harness = await GridHarness(appCount: 14, directory: dir)
    defer { harness.teardown() }
    try await harness.waitForIcons(1)

    harness.controller.moveSelection(deltaColumns: 0, deltaRows: 0)
    harness.controller.view.layoutSubtreeIfNeeded()

    let cell = try #require(harness.cell(at: 0))
    let tile = try #require(cell.selectionTileFrameForTesting)
    #expect(abs(tile.width - tile.height) < 1, "the tile was not square")
    // The icon view's frame is the icon's *canvas*; the artwork inside it is
    // smaller, so the tile lands close to the canvas rather than well past it.
    // Measured against the canvas: a tile the size of the frame would sit far
    // too loosely around the artwork, and one much larger overruns the cell.
    #expect(tile.width > cell.iconFrame.width * 0.9, "the tile crowded the icon")
    #expect(tile.width < cell.iconFrame.width * 1.15, "the tile was far larger than the icon")
    #expect(abs(tile.midX - cell.iconFrame.midX) < 1, "the tile was not centred on the icon")
    #expect(abs(tile.midY - cell.iconFrame.midY) < 1, "the tile was not centred on the icon")
}
