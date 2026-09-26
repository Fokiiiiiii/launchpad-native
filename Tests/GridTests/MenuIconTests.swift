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

/// The folder panel's menus come from SwiftUI with their symbols already in
/// place, so the setting is applied to the built menu — submenus included, and
/// whatever visibility an item arrived with.
@Test @MainActor func aBuiltMenuFollowsTheMenuIconSetting() {
    func builtMenu() -> NSMenu {
        let menu = NSMenu()
        let open = menuItem()
        open.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        menu.addItem(open)
        menu.addItem(.separator())
        let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        more.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        let nested = menuItem()
        nested.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        more.submenu = NSMenu()
        more.submenu?.addItem(nested)
        menu.addItem(more)
        return menu
    }
    func itemsWithSymbols(_ menu: NSMenu) -> [NSMenuItem] {
        [menu.items[0], menu.items[2]] + (menu.items[2].submenu?.items ?? [])
    }

    let hidden = builtMenu()
    MenuIcon.apply(.hidden, to: hidden)
    #expect(itemsWithSymbols(hidden).count == 3)
    #expect(itemsWithSymbols(hidden).allSatisfy { $0.image == nil })

    let visible = builtMenu()
    MenuIcon.apply(.visible, to: visible)
    #expect(itemsWithSymbols(visible).allSatisfy { $0.image != nil })
    if #available(macOS 27, *) {
        #expect(itemsWithSymbols(visible).allSatisfy { $0.preferredImageVisibility == .visible })
    }

    let automatic = builtMenu()
    if #available(macOS 27, *) {
        itemsWithSymbols(automatic).forEach { $0.preferredImageVisibility = .visible }
    }
    MenuIcon.apply(.automatic, to: automatic)
    #expect(itemsWithSymbols(automatic).allSatisfy { $0.image != nil })
    if #available(macOS 27, *) {
        #expect(itemsWithSymbols(automatic).allSatisfy { $0.preferredImageVisibility == .automatic })
    }
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
