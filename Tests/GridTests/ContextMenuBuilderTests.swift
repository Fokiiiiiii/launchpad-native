import Catalog
import Foundation
import Testing
@testable import Grid

import Carbon

private func contextMenuRecord() -> ApplicationRecord {
    ApplicationRecord(
        id: StableAppID(bundleURL: URL(fileURLWithPath: "/tmp/Test.app"), bundleIdentifier: "test", teamIdentifier: nil),
        bundleIdentifier: "test",
        bundleURL: URL(fileURLWithPath: "/tmp/Test.app"),
        executableURL: nil,
        displayName: "Test",
        originalDisplayName: "Test",
        bundleVersion: nil,
        teamIdentifier: nil,
        category: nil,
        sourceID: "test",
        isSystemProtected: false,
        isBackgroundOnly: false,
        iconCacheKey: "test",
        canLaunch: true,
        canOpenNewInstance: false,
        lastSeenModificationDate: Date(timeIntervalSince1970: 0)
    )
}

@Test @MainActor func addToDockItemRequiresAnAction() {
    let record = contextMenuRecord()
    let withoutDockAction = ContextMenuBuilder.menu(
        for: record,
        actions: .init(open: {}, showInFinder: {}, rename: {}, hide: {}, getInfo: {})
    )
    let withDockAction = ContextMenuBuilder.menu(
        for: record,
        actions: .init(open: {}, showInFinder: {}, addToDock: {}, rename: {}, hide: {}, getInfo: {})
    )

    #expect(withDockAction.items.count == withoutDockAction.items.count + 1)
}

@Test @MainActor func quitItemsAppearOnlyWhenActionsAreAvailable() {
    let record = contextMenuRecord()
    let without = ContextMenuBuilder.menu(for: record, actions: .init(open: {}, showInFinder: {}, rename: {}, hide: {}))
    var quitCount = 0
    var forceCount = 0
    let menu = ContextMenuBuilder.menu(for: record, actions: .init(open: {}, showInFinder: {}, rename: {}, hide: {}, quit: { quitCount += 1 }, forceQuit: { forceCount += 1 }))
    #expect(menu.items.count == without.items.count + 2)
    guard let quit = menu.items[1] as? ClosureMenuItem, let force = menu.items[2] as? ClosureMenuItem else {
        Issue.record("quit actions unavailable"); return
    }
    quit.invoke()
    force.invoke()
    #expect(quitCount == 1)
    #expect(forceCount == 1)
}

/// Get Info used to open Finder with the app selected — what Show in Finder
/// already does — so it is offered only when something really provides it.
@Test @MainActor func getInfoAppearsOnlyWhenThereIsSomethingToRun() {
    let record = contextMenuRecord()
    let without = ContextMenuBuilder.menu(for: record, actions: .init(open: {}, showInFinder: {}, rename: {}, hide: {}))
    let with = ContextMenuBuilder.menu(for: record, actions: .init(open: {}, showInFinder: {}, rename: {}, hide: {}, getInfo: {}))

    // The item and the separator in front of it.
    #expect(with.items.count == without.items.count + 2)
    #expect(without.items.last?.isSeparatorItem != true)
}

@Test func finderInfoEventPassesThePathAsData() throws {
    let path = "/tmp/a \"quoted\" name\nsecond line.app"
    let url = URL(fileURLWithPath: path)
    let event = try #require(FinderInfoAction.event(for: url))
    #expect(event.eventClass == AEEventClass(kASAppleScriptSuite))
    #expect(event.eventID == AEEventID(kASSubroutineEvent))
    #expect(event.paramDescriptor(forKeyword: AEKeyword(keyASSubroutineName))?.stringValue == "showInfo")
    #expect(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.atIndex(1)?.stringValue == url.path)
    #expect(FinderInfoAction.event(for: URL(string: "https://example.invalid/app")!) == nil)
}

@Test @MainActor func finderInfoEventInvokesLocalHandlerWithExactPath() throws {
    let url = URL(fileURLWithPath: "/tmp/name with spaces.app")
    let event = try #require(FinderInfoAction.event(for: url))
    let script = try #require(NSAppleScript(source: "on showInfo(posixPath)\nreturn posixPath\nend showInfo"))
    var error: NSDictionary?
    let result = script.executeAppleEvent(event, error: &error)
    #expect(error == nil)
    #expect(result.stringValue == url.path)
}

@Test @MainActor func hiddenMenuIconsLeaveEveryItemWithoutAnImage() {
    let record = contextMenuRecord()
    let appMenu = ContextMenuBuilder.menu(
        for: record,
        actions: .init(open: {}, showInFinder: {}, rename: {}, hide: {}, getInfo: {}),
        iconVisibility: .hidden
    )
    let folderMenu = ContextMenuBuilder.folderMenu(open: {}, rename: {}, ungroup: {}, iconVisibility: .hidden)

    #expect(appMenu.items.allSatisfy { $0.image == nil })
    #expect(folderMenu.items.allSatisfy { $0.image == nil })
}

/// The default keeps the symbols the menus have always had, so nothing changes
/// until the user picks something else.
@Test @MainActor func menusKeepTheirSymbolsByDefault() {
    let record = contextMenuRecord()
    let appMenu = ContextMenuBuilder.menu(
        for: record,
        actions: .init(open: {}, showInFinder: {}, rename: {}, hide: {}, getInfo: {})
    )
    let items = appMenu.items.filter { !$0.isSeparatorItem }

    #expect(!items.isEmpty)
    #expect(items.allSatisfy { $0.image != nil })
}
