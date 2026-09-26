import AppKit
import Catalog
import Localization
import Persistence

/// Builds the per-app context menu (2.7) purely from the record's actual
/// capabilities — never by matching on app name/bundle identifier.
public enum ContextMenuBuilder {
    public struct Actions {
        public var open: () -> Void
        public var openNewInstance: (() -> Void)?
        public var showInFinder: () -> Void
        public var addToDock: (() -> Void)? = nil
        public var rename: () -> Void
        public var hide: () -> Void
        public var getInfo: () -> Void
        public var showWindows: (() -> Void)?
        public var uninstall: (() -> Void)?
    }

    public static func menu(
        for record: ApplicationRecord,
        actions: Actions,
        iconVisibility: MenuIconVisibility = .automatic
    ) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(makeItem(L10n.menuOpen, symbolName: "arrow.up.forward.app", iconVisibility: iconVisibility, action: actions.open))

        if record.canOpenNewInstance, let openNewInstance = actions.openNewInstance {
            menu.addItem(makeItem(L10n.menuOpenNewInstance, symbolName: "macwindow.badge.plus", iconVisibility: iconVisibility, action: openNewInstance))
        }

        menu.addItem(.separator())
        menu.addItem(makeItem(L10n.menuShowInFinder, symbolName: "folder", iconVisibility: iconVisibility, action: actions.showInFinder))
        if let addToDock = actions.addToDock {
            menu.addItem(makeItem(L10n.menuAddToDock, symbolName: "dock.rectangle", iconVisibility: iconVisibility, action: addToDock))
        }

        menu.addItem(.separator())
        menu.addItem(makeItem(L10n.menuRename, symbolName: "pencil", iconVisibility: iconVisibility, action: actions.rename))
        menu.addItem(makeItem(L10n.menuHide, symbolName: "eye.slash", iconVisibility: iconVisibility, action: actions.hide))

        menu.addItem(.separator())
        if let showWindows = actions.showWindows {
            menu.addItem(makeItem(L10n.menuShowWindows, symbolName: "macwindow.on.rectangle", iconVisibility: iconVisibility, action: showWindows))
        }

        // System-protected apps (bundled with the OS) never get an Uninstall
        // item at all — `RemovalPlanner` collapses to a single `.unknown`
        // entry for those, so there's nothing useful the item could do.
        if !record.isSystemProtected, let uninstall = actions.uninstall {
            let item = makeItem(L10n.menuUninstall, symbolName: "trash", iconVisibility: iconVisibility, action: uninstall)
            item.toolTip = L10n.menuUninstallTooltip
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(makeItem(L10n.menuGetInfo, symbolName: "info.circle", iconVisibility: iconVisibility, action: actions.getInfo))

        return menu
    }

    public static func folderMenu(
        open: @escaping () -> Void,
        rename: @escaping () -> Void,
        ungroup: @escaping () -> Void,
        iconVisibility: MenuIconVisibility = .automatic
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem(L10n.menuOpen, symbolName: "arrow.up.forward.app", iconVisibility: iconVisibility, action: open))
        menu.addItem(makeItem(L10n.menuRenameFolder, symbolName: "pencil", iconVisibility: iconVisibility, action: rename))
        menu.addItem(makeItem(L10n.menuUngroupFolder, symbolName: "folder.badge.minus", iconVisibility: iconVisibility, action: ungroup))
        return menu
    }

    private static func makeItem(
        _ title: String,
        symbolName: String? = nil,
        iconVisibility: MenuIconVisibility,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.invoke), keyEquivalent: "")
        item.target = item
        item.actionClosure = action
        if let symbolName {
            MenuIcon.configure(item, symbolName: symbolName, visibility: iconVisibility)
        }
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
