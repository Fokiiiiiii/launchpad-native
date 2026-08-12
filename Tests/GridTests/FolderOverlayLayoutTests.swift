import Testing
@testable import Grid

@Test @MainActor func folderPanelWidthUsesOnlyTheNeededColumnsUntilTheGridIsFull() {
    #expect(FolderContentsViewController.panelWidth(availableWidth: 1_488, itemCount: 1, columns: 7, iconSize: 96) == 240)
    #expect(FolderContentsViewController.panelWidth(availableWidth: 1_488, itemCount: 3, columns: 7, iconSize: 96) == 500)
    #expect(FolderContentsViewController.panelWidth(availableWidth: 1_488, itemCount: 7, columns: 7, iconSize: 96) == 1_488)
}

@Test @MainActor func folderPanelWidthNeverExceedsTheAvailableTesseraWidth() {
    #expect(FolderContentsViewController.panelWidth(availableWidth: 600, itemCount: 14, columns: 7, iconSize: 96) == 600)
}
