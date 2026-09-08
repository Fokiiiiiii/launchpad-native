import Catalog
import Foundation
import Testing
@testable import Grid

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
