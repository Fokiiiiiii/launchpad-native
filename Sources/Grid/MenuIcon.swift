import AppKit
import Persistence

/// Attaches an SF Symbol to a menu item the way `MenuIconVisibility` asks.
///
/// macOS 27 hides symbol images in menus unless told otherwise, and says so
/// through `NSMenuItem.preferredImageVisibility`. Earlier systems always show
/// an item's image, so there the only lever is whether it gets one.
enum MenuIcon {
    static func configure(_ item: NSMenuItem, symbolName: String, visibility: MenuIconVisibility) {
        guard visibility != .hidden else {
            item.image = nil
            return
        }
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        if #available(macOS 27, *) {
            item.preferredImageVisibility = visibility == .visible ? .visible : .automatic
        }
    }

    /// For SwiftUI menus, which have no counterpart to
    /// `preferredImageVisibility`.
    ///
    /// `.visible` hands back an image AppKit does not treat as a symbol —
    /// macOS 27 hides only *symbol* images — drawn from the symbol on demand
    /// so it stays sharp at any scale, and marked as a template so it takes
    /// the menu's text colour the way the symbol would. `.automatic` is the
    /// plain symbol, left for the system to decide about.
    static func swiftUIImage(symbolName: String, visibility: MenuIconVisibility) -> NSImage? {
        guard visibility != .hidden,
              let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }
        guard visibility == .visible else { return symbol }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}
