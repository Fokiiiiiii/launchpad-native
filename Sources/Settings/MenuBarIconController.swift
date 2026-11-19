import AppKit
import Localization

/// A `NSStatusItem` for the app — with `LSUIElement` (no Dock icon), this
/// is the one persistently-visible entry point while the launcher itself
/// is hidden. Purely a discoverability affordance: every action here
/// (open, settings, quit) already has another way to trigger it (a
/// trigger, the launcher's own settings chip, Cmd-Q while the launcher is
/// key) — this doesn't introduce any new capability, just a menu-bar
/// shortcut to it.
@MainActor
public final class MenuBarIconController {
    private var statusItem: NSStatusItem?
    private let onOpenLauncher: () -> Void
    private let onOpenSettings: () -> Void

    public init(onOpenLauncher: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.onOpenLauncher = onOpenLauncher
        self.onOpenSettings = onOpenSettings
    }

    public func setVisible(_ visible: Bool) {
        if visible {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        applyIcon(to: item)

        let menu = NSMenu()
        menu.addItem(makeItem(L10n.menuBarOpenLauncherItem, action: #selector(handleOpenLauncher)))
        menu.addItem(makeItem(L10n.openSettingsMenuItem, action: #selector(handleOpenSettings)))
        menu.addItem(.separator())
        menu.addItem(makeItem(L10n.menuBarQuitItem, action: #selector(handleQuit), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    /// A template symbol, as the HIG asks of menu bar extras, so the system can
    /// tint it for light and dark menu bars and for the highlighted state.
    private func applyIcon(to item: NSStatusItem) {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        item.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: name)
    }

    private func hide() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func makeItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func handleOpenLauncher() {
        onOpenLauncher()
    }

    @objc private func handleOpenSettings() {
        onOpenSettings()
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}
