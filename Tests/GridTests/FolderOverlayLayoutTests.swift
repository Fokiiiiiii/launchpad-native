import AppKit
import Testing
@testable import Grid

// MARK: column count

/// A folder uses the same column count as the grid it came out of, so it reads
/// as a window onto the same layout.
@Test @MainActor func aFolderFollowsTheGridsColumnCount() {
    #expect(FolderContentsViewController.displayedColumnCount(itemCount: 9, configuredColumns: 6) == 6)
    #expect(FolderContentsViewController.displayedColumnCount(itemCount: 18, configuredColumns: 7) == 7)
}

/// A folder with fewer items than columns only uses the columns it needs, so
/// the tiles are not spread across a row that is mostly empty.
@Test @MainActor func aSparseFolderOnlyUsesTheColumnsItNeeds() {
    #expect(FolderContentsViewController.displayedColumnCount(itemCount: 2, configuredColumns: 7) == 2)
    #expect(FolderContentsViewController.displayedColumnCount(itemCount: 5, configuredColumns: 7) == 5)
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
    // Four rows of this grid's icons would be past the panel's share of the
    // screen, so they are stepped down.
    let stepped = FolderContentsViewController.folderIconSize(gridIconSize: 161.45, rows: 4, availableHeight: 1_050)
    #expect(stepped < 161.45)
    let rows = 4.0
    let height = rows * (stepped + 40) + (rows - 1) * 26 + 68 + 77
    #expect(height <= 1_050 * 0.75 + 0.001)
}

/// Fewer rows need less room, so the same grid icon size survives at one row
/// while being stepped down at three.
@Test @MainActor func fewerRowsKeepMoreOfTheGridsIconSize() {
    let twoRows = FolderContentsViewController.folderIconSize(gridIconSize: 161.45, rows: 2, availableHeight: 1_050)
    let fourRows = FolderContentsViewController.folderIconSize(gridIconSize: 161.45, rows: 4, availableHeight: 1_050)
    // Two rows — the common case once columns follow the grid — is untouched.
    #expect(twoRows == 161.45)
    #expect(fourRows < twoRows)
}

/// A short display must not shrink icons away to nothing.
@Test @MainActor func iconsNeverShrinkBelowAFloor() {
    #expect(FolderContentsViewController.folderIconSize(gridIconSize: 161.45, rows: 4, availableHeight: 300) == 48)
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

// MARK: panel placement

private let hostSize = NSSize(width: 1_600, height: 1_000)

/// The panel sits in the same centered position whatever the folder holds —
/// only its height changes with the contents.
@Test @MainActor func thePanelIsCenteredWhateverItHolds() {
    let small = FolderOverlayPresenter.panelFrame(size: NSSize(width: 1_408, height: 200), in: hostSize)
    let large = FolderOverlayPresenter.panelFrame(size: NSSize(width: 1_408, height: 700), in: hostSize)
    for frame in [small, large] {
        #expect(abs(frame.midX - hostSize.width / 2) < 0.001)
        #expect(abs(frame.midY - hostSize.height / 2) < 0.001)
    }
    #expect(small.width == large.width)
}

@Test @MainActor func placementNeverResizesThePanel() {
    let size = NSSize(width: 1_408, height: 400)
    #expect(FolderOverlayPresenter.panelFrame(size: size, in: hostSize).size == size)
}
