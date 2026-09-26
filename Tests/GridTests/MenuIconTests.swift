import AppKit
import Catalog
import Foundation
import Persistence
import Testing
@testable import Grid

private func menuItem() -> NSMenuItem {
    NSMenuItem(title: "Open", action: nil, keyEquivalent: "")
}

@Test @MainActor func hiddenMenuIconsAttachNoImage() {
    let item = menuItem()
    item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)

    MenuIcon.configure(item, symbolName: "folder", visibility: .hidden)

    #expect(item.image == nil)
}

/// `automatic` keeps the symbol and leaves showing it to the system: macOS 26
/// shows it, macOS 27 decides for itself and usually hides it.
@Test @MainActor func automaticMenuIconsLeaveTheDecisionToTheSystem() {
    let item = menuItem()

    MenuIcon.configure(item, symbolName: "folder", visibility: .automatic)

    #expect(item.image != nil)
    if #available(macOS 27, *) {
        #expect(item.preferredImageVisibility == .automatic)
    }
}

@Test @MainActor func visibleMenuIconsAskTheSystemToKeepThem() {
    let item = menuItem()

    MenuIcon.configure(item, symbolName: "folder", visibility: .visible)

    #expect(item.image != nil)
    if #available(macOS 27, *) {
        #expect(item.preferredImageVisibility == .visible)
    }
}

/// SwiftUI menus cannot ask for `preferredImageVisibility`, so showing the icon
/// there means handing over an image AppKit does not treat as a symbol — macOS
/// 27 only hides symbol images.
@Test @MainActor func swiftUIMenusAreGivenAnImageTheSystemDoesNotHide() throws {
    #expect(MenuIcon.swiftUIImage(symbolName: "folder", visibility: .hidden) == nil)

    let automatic = try #require(MenuIcon.swiftUIImage(symbolName: "folder", visibility: .automatic))
    #expect(!automatic.representations.contains { $0 is NSCustomImageRep }, "automatic should stay the plain symbol")

    let visible = try #require(MenuIcon.swiftUIImage(symbolName: "folder", visibility: .visible))
    #expect(visible.isTemplate, "it has to take the menu's text colour like the symbol would")
    #expect(visible.representations.allSatisfy { $0 is NSCustomImageRep }, "a symbol image would be hidden on macOS 27")
    #expect(visible.size == automatic.size)
}

private func menuRecord() -> ApplicationRecord {
    ApplicationRecord(
        id: StableAppID(bundleURL: URL(fileURLWithPath: "/tmp/Menu.app"), bundleIdentifier: "menu", teamIdentifier: nil),
        bundleIdentifier: "menu",
        bundleURL: URL(fileURLWithPath: "/tmp/Menu.app"),
        executableURL: nil,
        displayName: "Menu",
        originalDisplayName: "Menu",
        bundleVersion: nil,
        teamIdentifier: nil,
        category: nil,
        sourceID: "test",
        isSystemProtected: false,
        isBackgroundOnly: false,
        isMenuBarApp: false,
        iconCacheKey: "menu",
        canLaunch: true,
        canOpenNewInstance: true,
        lastSeenModificationDate: Date(timeIntervalSince1970: 0)
    )
}

/// The setting reaches the menus the grid and the search results actually open
/// — both come from `GridViewController.contextMenu(for:anchorView:)`, which
/// reads the model each time a menu is built.
@Test @MainActor func theGridsMenusFollowTheMenuIconSetting() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = GridModel(layoutStore: LayoutStore(directory: dir))
    await model.loadDocument()
    let record = menuRecord()
    model.reconcile(with: [record])
    let controller = GridViewController(model: model, iconCache: IconCache(), onLaunch: { _ in }, onBackgroundClick: {})

    model.setMenuIconVisibility(.hidden)
    #expect(controller.contextMenu(for: record, anchorView: nil).items.allSatisfy { $0.image == nil })

    model.setMenuIconVisibility(.visible)
    let items = controller.contextMenu(for: record, anchorView: nil).items.filter { !$0.isSeparatorItem }
    #expect(!items.isEmpty)
    #expect(items.allSatisfy { $0.image != nil })
    if #available(macOS 27, *) {
        #expect(items.allSatisfy { $0.preferredImageVisibility == .visible })
    }
}
