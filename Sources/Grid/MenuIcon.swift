import AppKit
import Persistence

/// Shows or hides a menu's SF Symbols the way `MenuIconVisibility` asks.
///
/// macOS 27 hides menu images unless told otherwise, and takes that through
/// `NSMenuItem.preferredImageVisibility`. It hides every kind of image, not
/// only symbols: a menu measured on 27.0 made no room for a drawn or a bitmap
/// image either, and did for a symbol only once it was marked `.visible`.
/// Earlier systems always show an item's image, so there the only lever is
/// whether it has one.
enum MenuIcon {
    static func configure(_ item: NSMenuItem, symbolName: String, visibility: MenuIconVisibility) {
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        apply(visibility, to: item)
    }

    /// For a menu SwiftUI builds: its items already carry their symbols, and
    /// SwiftUI has no counterpart to `preferredImageVisibility`, so the setting
    /// is applied to the built menu on its way to AppKit.
    static func apply(_ visibility: MenuIconVisibility, to menu: NSMenu) {
        for item in menu.items {
            apply(visibility, to: item)
            if let submenu = item.submenu {
                apply(visibility, to: submenu)
            }
        }
    }

    private static func apply(_ visibility: MenuIconVisibility, to item: NSMenuItem) {
        guard visibility != .hidden else {
            item.image = nil
            return
        }
        if #available(macOS 27, *) {
            item.preferredImageVisibility = visibility == .visible ? .visible : .automatic
        }
    }
}
