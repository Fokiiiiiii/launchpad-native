import Testing
@testable import Grid

@Test @MainActor func folderPanelWidthUsesOnlyTheNeededColumnsUntilTheGridIsFull() {
    #expect(FolderContentsViewController.displayedColumnCount(itemCount: 1, configuredColumns: 7) == 1)
    #expect(FolderContentsViewController.displayedColumnCount(itemCount: 3, configuredColumns: 7) == 3)
    #expect(FolderContentsViewController.displayedColumnCount(itemCount: 7, configuredColumns: 7) == 7)
    #expect(FolderContentsViewController.displayedColumnCount(itemCount: 14, configuredColumns: 7) == 7)
    #expect(FolderContentsViewController.panelWidth(availableWidth: 1_488, columns: 1, iconSize: 96, usesWideLayout: false) == 240)
    #expect(FolderContentsViewController.panelWidth(availableWidth: 1_488, columns: 3, iconSize: 96, usesWideLayout: false) == 500)
    #expect(FolderContentsViewController.panelWidth(availableWidth: 1_488, columns: 7, iconSize: 96, usesWideLayout: true) == 1_488)
}

@Test @MainActor func folderPanelWidthNeverExceedsTheAvailablePanelWidth() {
    #expect(FolderContentsViewController.panelWidth(availableWidth: 600, columns: 7, iconSize: 96, usesWideLayout: true) == 600)
}
