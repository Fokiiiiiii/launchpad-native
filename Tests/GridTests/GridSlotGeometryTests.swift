import AppKit
import Persistence
import Testing
@testable import Grid

private func settings(columns: Int = 7, rows: Int = 5) -> GridSettings {
    GridSettings(
        columns: columns,
        rows: rows,
        horizontalSpacing: 20,
        verticalSpacing: 20,
        labelVisible: true,
        pageMargins: 40,
        folderGridSize: 9
    )
}

private let cell = CGSize(width: 120, height: 140)

// MARK: frameForSlot ≡ PagedGridLayout

/// The drag machinery measures hysteresis against `frameForSlot`, while the
/// real cells are positioned by `PagedGridLayout`. If the two ever disagree,
/// a drag highlights one cell and drops into another — and until now nothing
/// checked that they matched.
@Test @MainActor func slotFramesMatchTheRealLayoutForEverySlotOnAPage() {
    let config = settings()
    let layout = PagedGridLayout()
    layout.settings = config

    let collectionView = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 1_400, height: 900))
    collectionView.collectionViewLayout = layout
    let dataSource = FixedCountDataSource(count: config.columns * config.rows)
    collectionView.dataSource = dataSource
    collectionView.reloadData()
    layout.prepare()

    let cellSize = layout.currentCellSize
    #expect(cellSize.width > 1)
    #expect(cellSize.height > 1)

    for slot in 0..<(config.columns * config.rows) {
        guard let expected = layout.layoutAttributesForItem(at: IndexPath(item: slot, section: 0))?.frame else {
            Issue.record("no layout attributes for slot \(slot)")
            continue
        }
        let actual = GridSlotGeometry.frameForSlot(
            slot,
            columns: config.columns,
            cellSize: cellSize,
            horizontalSpacing: CGFloat(config.horizontalSpacing),
            verticalSpacing: CGFloat(config.verticalSpacing),
            margin: CGFloat(config.pageMargins)
        )
        #expect(abs(actual.origin.x - expected.origin.x) < 0.001, "slot \(slot) x")
        #expect(abs(actual.origin.y - expected.origin.y) < 0.001, "slot \(slot) y")
        #expect(abs(actual.width - expected.width) < 0.001, "slot \(slot) width")
        #expect(abs(actual.height - expected.height) < 0.001, "slot \(slot) height")
    }
}

private final class FixedCountDataSource: NSObject, NSCollectionViewDataSource {
    private let count: Int
    init(count: Int) { self.count = count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        NSCollectionViewItem()
    }
}

// MARK: insertionSlot

/// The bug this guards: clamping the column only *after* folding it into the
/// row index made a point past the right edge wrap onto the next row, so
/// dropping to the right of a row's last icon inserted somewhere unrelated.
@Test func aPointPastTheRightEdgeStaysOnItsOwnRow() {
    let slot = GridSlotGeometry.insertionSlot(
        forPoint: CGPoint(x: 10_000, y: 20),
        columns: 7,
        cellSize: cell,
        horizontalSpacing: 20,
        verticalSpacing: 20,
        margin: 40,
        occupiedSlots: 34
    )
    #expect(slot == 6)
}

@Test func pointsBeforeTheGridClampToTheFirstSlot() {
    let slot = GridSlotGeometry.insertionSlot(
        forPoint: CGPoint(x: -500, y: -500),
        columns: 7,
        cellSize: cell,
        horizontalSpacing: 20,
        verticalSpacing: 20,
        margin: 40,
        occupiedSlots: 34
    )
    #expect(slot == 0)
}

@Test func pointsBelowTheLastRowClampToTheAppendPosition() {
    let slot = GridSlotGeometry.insertionSlot(
        forPoint: CGPoint(x: 60, y: 100_000),
        columns: 7,
        cellSize: cell,
        horizontalSpacing: 20,
        verticalSpacing: 20,
        margin: 40,
        occupiedSlots: 12
    )
    #expect(slot == 12)
}

/// After a mid-drag page turn the dragged item is not on the visible page, so
/// no slot is freed and the drop may land at `count` (append). Callers express
/// that by passing the full count as `occupiedSlots`.
@Test func occupiedSlotsBoundsTheResult() {
    let point = CGPoint(x: 10_000, y: 100_000)
    let onItsOwnPage = GridSlotGeometry.insertionSlot(
        forPoint: point, columns: 7, cellSize: cell,
        horizontalSpacing: 20, verticalSpacing: 20, margin: 40, occupiedSlots: 23
    )
    let afterAPageTurn = GridSlotGeometry.insertionSlot(
        forPoint: point, columns: 7, cellSize: cell,
        horizontalSpacing: 20, verticalSpacing: 20, margin: 40, occupiedSlots: 24
    )
    #expect(onItsOwnPage == 23)
    #expect(afterAPageTurn == 24)
}

// MARK: hysteresis

/// The regression that motivated making this 2D: judged on `x` alone, a
/// straight vertical drag never cleared the threshold, so the icon under the
/// pointer refused to move aside however far the drag went.
@Test func straightVerticalMovementCanClearTheHysteresisThreshold() {
    let frame = CGRect(x: 0, y: 0, width: 120, height: 140)
    let straightUp = CGPoint(x: frame.midX, y: frame.midY + 100)
    #expect(GridSlotGeometry.exceedsHysteresis(point: straightUp, committedFrame: frame, fraction: 0.18))
}

@Test func smallMovementsAroundTheCenterDoNotClearTheThreshold() {
    let frame = CGRect(x: 0, y: 0, width: 120, height: 140)
    for (dx, dy) in [(0.0, 0.0), (5.0, 5.0), (-8.0, 3.0), (0.0, -10.0)] {
        let point = CGPoint(x: frame.midX + dx, y: frame.midY + dy)
        #expect(!GridSlotGeometry.exceedsHysteresis(point: point, committedFrame: frame, fraction: 0.18))
    }
}

@Test func theThresholdIsARadiusNotAnAxisComparison() {
    let frame = CGRect(x: 0, y: 0, width: 120, height: 120)
    // Just outside the radius diagonally, while neither axis alone is far.
    let radius = 120 * 0.18
    let offset = radius * 0.8
    let diagonal = CGPoint(x: frame.midX + offset, y: frame.midY + offset)
    #expect(GridSlotGeometry.exceedsHysteresis(point: diagonal, committedFrame: frame, fraction: 0.18))
}

// MARK: preview slot mapping

/// The live preview assigns each non-dragged item a destination slot. If that
/// mapping is ever not a permutation, two icons animate into one slot and
/// another is left empty.
@Test func previewSlotMappingIsAPermutationForEveryCandidate() {
    for count in 1...24 {
        for candidateSlot in 0...(count - 1) {
            var destinations: [Int] = []
            for naturalPosition in 0..<(count - 1) {
                destinations.append(
                    GridSlotGeometry.previewSlot(naturalPosition: naturalPosition, candidateSlot: candidateSlot)
                )
            }
            #expect(Set(destinations).count == destinations.count, "count=\(count) candidate=\(candidateSlot): duplicates")
            let occupied = Set(destinations + [candidateSlot])
            #expect(occupied == Set(0..<count), "count=\(count) candidate=\(candidateSlot): gaps or overflow")
        }
    }
}

// MARK: folder zone

@Test func theFolderZoneIsTheCenteredPortionOfTheCell() {
    let frame = CGRect(x: 100, y: 200, width: 120, height: 140)
    let zone = GridSlotGeometry.folderZone(in: frame, inset: 0.2)
    #expect(zone.midX == frame.midX)
    #expect(zone.midY == frame.midY)
    #expect(zone.contains(CGPoint(x: frame.midX, y: frame.midY)))
    // A corner of the cell must not count as a folder drop.
    #expect(!zone.contains(CGPoint(x: frame.minX + 1, y: frame.minY + 1)))
}

// MARK: dragged item's slot across page turns

/// Reported bug: dragging an app to the next page and back made a duplicate of
/// it appear at its original position. Carrying the drag off its origin page
/// correctly stops excluding that slot, but coming *back* has to start
/// excluding it again — otherwise the item's own cell is drawn underneath the
/// floating icon the user is still holding.
@Test func draggedItemIsExcludedAgainWhenTheDragReturnsToItsOriginPage() {
    let sourcePage = 1
    let sourceIndex = 5

    // Away from the origin page: nothing to exclude.
    #expect(ItemDrag.sourceIndex(onPage: 0, sourcePage: sourcePage, sourceOriginalIndex: sourceIndex) == nil)
    #expect(ItemDrag.sourceIndex(onPage: 2, sourcePage: sourcePage, sourceOriginalIndex: sourceIndex) == nil)

    // Back on the origin page: the item occupies its original slot again.
    #expect(ItemDrag.sourceIndex(onPage: sourcePage, sourcePage: sourcePage, sourceOriginalIndex: sourceIndex) == sourceIndex)
}

/// The whole round trip, in the order a real drag performs it.
@Test func aPageTurnRoundTripEndsWithTheSameExclusionItStartedWith() {
    let sourcePage = 0
    let sourceIndex = 3
    let visited = [sourcePage, 1, 2, 1, sourcePage]
    let exclusions = visited.map {
        ItemDrag.sourceIndex(onPage: $0, sourcePage: sourcePage, sourceOriginalIndex: sourceIndex)
    }
    #expect(exclusions == [sourceIndex, nil, nil, nil, sourceIndex])
}
