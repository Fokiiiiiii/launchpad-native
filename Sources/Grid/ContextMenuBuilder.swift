import AppKit
import Catalog
import Localization

/// Builds the per-app context menu (2.7) purely from the record's actual
/// capabilities — never by matching on app name/bundle identifier.
public enum ContextMenuBuilder {
    public struct Actions {
        public var open: () -> Void
        public var openNewInstance: (() -> Void)?
        public var showInFinder: () -> Void
        public var addToDock: () -> Void
        public var rename: () -> Void
        public var hide: () -> Void
        public var removeFromFolder: (() -> Void)?
        public var getInfo: () -> Void
        public var showWindows: (() -> Void)?
        public var uninstall: (() -> Void)?
    }

    public static func menu(for record: ApplicationRecord, isInFolder: Bool, actions: Actions) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(makeItem(L10n.menuOpen, action: actions.open))

        if record.canOpenNewInstance, let openNewInstance = actions.openNewInstance {
            menu.addItem(makeItem(L10n.menuOpenNewInstance, action: openNewInstance))
        }

        menu.addItem(.separator())
        menu.addItem(makeItem(L10n.menuShowInFinder, action: actions.showInFinder))
        menu.addItem(makeItem(L10n.menuAddToDock, action: actions.addToDock))

        menu.addItem(.separator())
        menu.addItem(makeItem(L10n.menuRename, action: actions.rename))
        menu.addItem(makeItem(L10n.menuHide, action: actions.hide))
        if isInFolder, let removeFromFolder = actions.removeFromFolder {
            menu.addItem(makeItem(L10n.menuRemoveFromFolder, action: removeFromFolder))
        }

        menu.addItem(.separator())
        if let showWindows = actions.showWindows {
            menu.addItem(makeItem(L10n.menuShowWindows, action: showWindows))
        }

        // System-protected apps (bundled with the OS) never get an Uninstall
        // item at all — `RemovalPlanner` would reject them outright, so
        // there's nothing useful the item could do for one.
        if !record.isSystemProtected, let uninstall = actions.uninstall {
            let item = makeItem(L10n.menuUninstall, action: uninstall)
            item.toolTip = L10n.menuUninstallTooltip
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(makeItem(L10n.menuGetInfo, action: actions.getInfo))

        return menu
    }

    public static func folderMenu(rename: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem(L10n.menuRenameFolder, action: rename))
        return menu
    }

    private static func makeItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.invoke), keyEquivalent: "")
        item.target = item
        item.actionClosure = action
        return item
    }
}

/// `NSMenuItem` doesn't take a closure directly; this small subclass routes
/// the item's action back to a stored closure instead of requiring a
/// delegate object per menu.
final class ClosureMenuItem: NSMenuItem {
    var actionClosure: (() -> Void)?

    @objc func invoke() {
        actionClosure?()
    }
}
