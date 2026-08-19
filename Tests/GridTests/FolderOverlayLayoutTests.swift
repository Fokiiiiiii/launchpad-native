import AppKit
import Testing
@testable import Grid

// MARK: column count

/// A folder is laid out around three rows, so the column count comes from how
/// many items it holds — not from the main grid's own column count, which used
/// to make nine items a row of six with three stragglers under it.
@Test @MainActor func aFolderGrowsColumnsWhileKeepingThreeRows() {
    let columnsFor = { count in
        FolderContentsViewController.displayedColumnCount(itemCount: count, configuredColumns: 7)
    }
    #expect(columnsFor(6) == 2)   // 2×3
    #expect(columnsFor(9) == 3)   // 3×3
    #expect(columnsFor(12) == 4)  // 4×3
    // Partly-filled last rows still size to three rows, never four.
    #expect(columnsFor(7) == 3)
    #expect(columnsFor(8) == 3)
}

/// Up to three items belong on one row — turning two apps into a single column
/// two rows tall would be a stranger shape than the one being fixed.
@Test @MainActor func threeOrFewerItemsStayOnOneRow() {
    for count in 1...3 {
        #expect(FolderContentsViewController.displayedColumnCount(itemCount: count, configuredColumns: 7) == count)
    }
}

/// The grid's own column count is the ceiling: past it the folder gains rows
/// (and scrolls) rather than growing wider without limit.
@Test @MainActor func theMainGridsColumnCountCapsHowWideAFolderGets() {
    #expect(FolderContentsViewController.displayedColumnCount(itemCount: 30, configuredColumns: 7) == 7)
    #expect(FolderContentsViewController.displayedColumnCount(itemCount: 30, configuredColumns: 4) == 4)
}

@Test @MainActor func anEmptyFolderStillHasOneColumn() {
    #expect(FolderContentsViewController.displayedColumnCount(itemCount: 0, configuredColumns: 7) == 1)
}

// MARK: panel width

@Test @MainActor func panelWidthFollowsTheColumnCountItWasGiven() {
    #expect(FolderContentsViewController.panelWidth(availableWidth: 1_488, columns: 1, iconSize: 96) == 240)
    #expect(FolderContentsViewController.panelWidth(availableWidth: 1_488, columns: 3, iconSize: 96) == 500)
}

/// The panel is sized to what it holds at the icon size the grid is currently
/// drawn at — making the icons bigger has to make the folder behind them
/// bigger too, rather than leaving them crowded in a fixed box.
@Test @MainActor func panelWidthGrowsWithTheIconSize() {
    let small = FolderContentsViewController.panelWidth(availableWidth: 1_488, columns: 3, iconSize: 96)
    let large = FolderContentsViewController.panelWidth(availableWidth: 1_488, columns: 3, iconSize: 160)
    #expect(large > small)
    // Three columns of (icon + label allowance), plus the grid's own insets.
    #expect(abs(large - (3 * (160 + 56) + 44)) < 0.001)
}

@Test @MainActor func panelWidthNeverExceedsTheSpaceAvailable() {
    #expect(FolderContentsViewController.panelWidth(availableWidth: 600, columns: 7, iconSize: 96) == 600)
}

// MARK: folder icon size

/// A grid with modest icons gets its own size back — the folder should look
/// like the grid it came out of, and there is nothing to fix.
@Test @MainActor func aFolderKeepsTheGridsIconSizeWhenItFits() {
    #expect(FolderContentsViewController.folderIconSize(gridIconSize: 96, rows: 3, availableHeight: 1_050) == 96)
    #expect(FolderContentsViewController.folderIconSize(gridIconSize: 72, rows: 3, availableHeight: 1_050) == 72)
}

/// …but this grid's icons can be set large enough that three rows of them would
/// be most of the display, which reads as an oversized folder however correctly
/// it is laid out ("なんかデカすぎる気がする").
@Test @MainActor func oversizedGridIconsAreSteppedDownToFit() {
    let stepped = FolderContentsViewController.folderIconSize(gridIconSize: 161.45, rows: 3, availableHeight: 1_050)
    #expect(stepped < 161.45)
    // The rows it produces have to actually fit the share of the screen the
    // panel is allowed.
    let rows = 3.0
    let height = rows * (stepped + 40) + (rows - 1) * 26 + 68 + 77
    #expect(height <= 1_050 * 0.62 + 0.001)
}

/// Fewer rows need less room, so the same grid icon size survives at one row
/// while being stepped down at three.
@Test @MainActor func fewerRowsKeepMoreOfTheGridsIconSize() {
    let oneRow = FolderContentsViewController.folderIconSize(gridIconSize: 161.45, rows: 1, availableHeight: 1_050)
    let threeRows = FolderContentsViewController.folderIconSize(gridIconSize: 161.45, rows: 3, availableHeight: 1_050)
    #expect(oneRow == 161.45)
    #expect(threeRows < oneRow)
}

/// A short display must not shrink icons away to nothing.
@Test @MainActor func iconsNeverShrinkBelowAFloor() {
    #expect(FolderContentsViewController.folderIconSize(gridIconSize: 161.45, rows: 3, availableHeight: 300) == 48)
}

// MARK: panel height

/// The cap is a share of the screen rather than a fixed number: the flat 480pt
/// it replaced clipped a second row that had plenty of room on a large display.
@Test @MainActor func maximumPanelHeightScalesWithTheScreen() {
    #expect(FolderContentsViewController.maximumPanelHeight(availableHeight: 1_050) > 600)
    #expect(FolderContentsViewController.maximumPanelHeight(availableHeight: 1_600)
            > FolderContentsViewController.maximumPanelHeight(availableHeight: 1_050))
}

/// …but a very short display must not collapse the card to nothing.
@Test @MainActor func maximumPanelHeightHasAFloor() {
    #expect(FolderContentsViewController.maximumPanelHeight(availableHeight: 200) == 320)
}

// MARK: band placement

private let hostSize = NSSize(width: 1_600, height: 1_000)

/// A band that fits below its folder icon grows out of it, notch and all —
/// the connection the system's own folder panel makes.
@Test @MainActor func aBandThatFitsSitsBelowItsIconAndKeepsItsNotch() {
    // AppKit's y axis runs upward, so "below the icon" is a smaller maxY.
    let icon = NSRect(x: 700, y: 700, width: 100, height: 100)
    let placement = FolderOverlayPresenter.bandPlacement(
        size: NSSize(width: 1_408, height: 400),
        in: hostSize,
        anchorIconFrame: icon
    )
    #expect(placement.showsNotch)
    #expect(placement.frame.maxY < icon.minY)
    // Horizontally centered on screen — only the notch tracks the icon.
    #expect(abs(placement.frame.midX - hostSize.width / 2) < 0.001)
}

/// This grid's icons can be large enough that a three-row folder is most of the
/// screen tall. Forcing that under its icon would pin it to the top with the
/// icon buried inside it, so it centers — and drops the notch, which would
/// otherwise point at something the band itself covers.
@Test @MainActor func aBandTooTallToFitBelowItsIconCentersWithoutANotch() {
    let icon = NSRect(x: 700, y: 540, width: 160, height: 160)
    let placement = FolderOverlayPresenter.bandPlacement(
        size: NSSize(width: 1_488, height: 800),
        in: hostSize,
        anchorIconFrame: icon
    )
    #expect(placement.showsNotch == false)
    #expect(abs(placement.frame.midY - hostSize.height / 2) < 0.001)
}

/// A folder low on the grid leaves no room underneath either.
@Test @MainActor func aFolderNearTheBottomCentersInstead() {
    let icon = NSRect(x: 700, y: 120, width: 100, height: 100)
    let placement = FolderOverlayPresenter.bandPlacement(
        size: NSSize(width: 1_408, height: 400),
        in: hostSize,
        anchorIconFrame: icon
    )
    #expect(placement.showsNotch == false)
    #expect(placement.frame.minY >= 0)
}

/// Without an anchor — a folder opened from a debug hook, where no cell is
/// realized — there is nothing to point at.
@Test @MainActor func theBandCentersWhenThereIsNoAnchor() {
    let placement = FolderOverlayPresenter.bandPlacement(
        size: NSSize(width: 1_408, height: 400),
        in: hostSize,
        anchorIconFrame: nil
    )
    #expect(placement.showsNotch == false)
    #expect(abs(placement.frame.midY - hostSize.height / 2) < 0.001)
    #expect(abs(placement.frame.midX - hostSize.width / 2) < 0.001)
}

/// Whatever the outcome, the band keeps the size it was given.
@Test @MainActor func placementNeverResizesTheBand() {
    let size = NSSize(width: 1_408, height: 400)
    for anchor in [NSRect(x: 700, y: 700, width: 100, height: 100), NSRect(x: 700, y: 120, width: 100, height: 100)] {
        #expect(FolderOverlayPresenter.bandPlacement(size: size, in: hostSize, anchorIconFrame: anchor).frame.size == size)
    }
}
