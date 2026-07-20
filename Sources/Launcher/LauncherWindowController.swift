import AppKit
import Catalog
import Diagnostics
import Grid
import Persistence

/// Owns the single launcher window instance for the whole app — callers
/// never create a second one, which is what satisfies "複数ディスプレイで
/// 同時に複数インスタンスを表示しない": there is exactly one window, moved
/// to whichever screen is relevant each time it opens.
@MainActor
public final class LauncherWindowController: NSObject, NSWindowDelegate {
    private var window: LauncherWindow?
    private var viewController: LauncherViewController?
    private let viewModel = LauncherViewModel()
    private let gridModel: GridModel
    private let iconCache: IconCache
    private var isVisible = false
    private var hasAttemptedLegacyImport = false

    public init(iconCache: IconCache, layoutStore: LayoutStore) {
        self.iconCache = iconCache
        self.gridModel = GridModel(layoutStore: layoutStore)
        super.init()
    }

    public func loadGridDocument() async {
        await gridModel.loadDocument()
    }

    public var triggerSettings: TriggerSettings {
        gridModel.triggerSettings
    }

    public func updateTriggerSettings(_ settings: TriggerSettings) async {
        gridModel.updateTriggerSettings(settings)
        await gridModel.save()
    }

    public func updateRecords(_ records: [ApplicationRecord]) {
        viewModel.setRecords(records)

        // Legacy import must run BEFORE reconcile: `applyLegacyImportIfFirstRun`
        // only applies when the grid is still completely empty, and
        // `reconcile` itself fills the grid (alphabetically) with anything
        // unplaced — running reconcile first would make every subsequent
        // import attempt see a "non-empty" grid and silently no-op.
        if !hasAttemptedLegacyImport {
            hasAttemptedLegacyImport = true
            if let dbURL = LegacyLaunchpadImporter.defaultDatabaseURL() {
                let result = LegacyLaunchpadImporter.importLegacyLayout(from: dbURL, matching: records)
                if gridModel.applyLegacyImportIfFirstRun(result) {
                    DiagnosticsLog.launcher.info(
                        "Imported legacy Launchpad layout: \(result.folders.count, privacy: .public) folders, \(result.unresolvedBundleIDs.count, privacy: .public) unresolved bundle IDs"
                    )
                }
            }
        }

        gridModel.reconcile(with: records)
        viewController?.reloadGrid()
        Task { await gridModel.save() }
    }

    /// Same-trigger reinvocation closes it; otherwise it opens (or moves to
    /// the current pointer's screen if already open elsewhere).
    public func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    public func show() {
        let screen = Self.targetScreen()
        let window = window ?? makeWindow(on: screen)
        window.setFrame(screen.frame, display: true)
        viewController?.resetSearch()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isVisible = true
    }

    public func hide() {
        window?.orderOut(nil)
        isVisible = false
    }

    private func makeWindow(on screen: NSScreen) -> LauncherWindow {
        let window = LauncherWindow(contentRect: screen.frame)
        window.delegate = self
        window.onCancel = { [weak self] in self?.hide() }

        let content = LauncherViewController(
            viewModel: viewModel,
            gridModel: gridModel,
            iconCache: iconCache,
            onDidLaunch: { [weak self] in self?.hide() },
            onDidCancel: { [weak self] in self?.hide() }
        )

        let background = GlassBackgroundFactory.makeBackground(cornerRadius: 0)
        GlassBackgroundFactory.setContent(content.view, on: background)
        let containerController = NSViewController()
        containerController.view = background
        window.contentViewController = containerController

        self.window = window
        self.viewController = content
        return window
    }

    /// "ポインタまたはアクティブウインドウが存在するディスプレイ" — the
    /// pointer's screen is checked first; if that lookup fails for any
    /// reason, fall back to the key window's screen, then the main screen.
    private static func targetScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return screen
        }
        if let keyScreen = NSApp.keyWindow?.screen {
            return keyScreen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        // Clicking another app or the desktop resigns key — that's the
        // "click outside" close condition. A click on the launcher's own
        // empty background is handled separately by
        // `BackgroundClickCatcherView`, since that click stays inside this
        // window and never resigns key.
        hide()
    }
}
