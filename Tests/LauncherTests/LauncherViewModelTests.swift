import Catalog
import Foundation
import Testing
@testable import Launcher

func record(
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

@Test @MainActor func menuBarSearchPolicyUpdatesLive() {
    let vm = LauncherViewModel()
    let records = [
        record("Normal", id: "normal"),
        record("CodexBar", id: "menubar", menuBarApp: true),
        record("Agent", id: "agent", backgroundOnly: true)
    ]
    vm.setRecords(records)
    // LSBackgroundOnly is always omitted; LSUIElement is visible by default.
    #expect(vm.filteredRecords.map(\.displayName) == ["Normal", "CodexBar"])
    vm.setShowMenuBarApplications(false)
    #expect(vm.filteredRecords.map(\.displayName) == ["Normal"])
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

@Test @MainActor func queryChangeStartsFromTheBestMatch() {
    let vm = LauncherViewModel()
    vm.setRecords([record("Alpha", id: "a"), record("Beta", id: "b")])
    vm.select(index: 1) // Beta
    vm.setQuery("a")
    #expect(vm.selectedIndex == 0)
    #expect(vm.selectedRecord?.displayName == "Alpha")
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

/// A renamed app has to be reachable by the name the user actually sees. The
/// alias lives in the layout, not the catalog, so the index has to be handed
/// it explicitly — the catalog name keeps working too.
@Test @MainActor func aRenamedAppIsFoundByTheNameTheUserGaveIt() {
    let vm = LauncherViewModel()
    let notes = record("メモ", id: "com.apple.Notes")
    let other = record("Numbers", id: "com.apple.Numbers")
    vm.setRecords([notes, other], aliases: [notes.id: "notepad"])

    vm.setQuery("notepad")
    #expect(vm.filteredRecords.map(\.id) == [notes.id], "the alias should match")

    vm.setQuery("note")
    #expect(vm.filteredRecords.first?.id == notes.id, "a prefix of the alias should rank it first")

    vm.setQuery("メモ")
    #expect(vm.filteredRecords.map(\.id) == [notes.id], "the catalog name must keep working after a rename")

    // An app with no alias is unaffected by the extra tier checks.
    vm.setQuery("numbers")
    #expect(vm.filteredRecords.map(\.id) == [other.id])
}
