import Catalog
import Foundation
import Testing
@testable import Launcher

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

@Test @MainActor func selectionDefaultsToFirstItemAfterSettingRecords() {
    let vm = LauncherViewModel()
    vm.setRecords([record("A", id: "a"), record("B", id: "b")])
    #expect(vm.selectedIndex == 0)
    #expect(vm.selectedRecord?.displayName == "A")
}

@Test @MainActor func moveSelectionClampsAtBounds() {
    let vm = LauncherViewModel()
    vm.setRecords([record("A", id: "a"), record("B", id: "b")])
    vm.moveSelection(by: -5)
    #expect(vm.selectedIndex == 0)
    vm.moveSelection(by: 5)
    #expect(vm.selectedIndex == 1)
}

@Test @MainActor func selectionSurvivesQueryChangeWhenStillPresent() {
    let vm = LauncherViewModel()
    vm.setRecords([record("Alpha", id: "a"), record("Beta", id: "b")])
    vm.select(index: 1) // Beta
    vm.setQuery("Beta")
    #expect(vm.selectedRecord?.displayName == "Beta")
}

@Test @MainActor func selectionResetsWhenFilteredListBecomesEmpty() {
    let vm = LauncherViewModel()
    vm.setRecords([record("Alpha", id: "a")])
    vm.setQuery("nonexistent-xyz")
    #expect(vm.selectedIndex == nil)
    #expect(vm.selectedRecord == nil)
}

@Test @MainActor func onChangeFiresOnSetRecordsAndSelection() {
    let vm = LauncherViewModel()
    var changeCount = 0
    vm.onChange = { changeCount += 1 }
    vm.setRecords([record("A", id: "a"), record("B", id: "b")])
    vm.moveSelection(by: 1)
    #expect(changeCount == 2)
}
