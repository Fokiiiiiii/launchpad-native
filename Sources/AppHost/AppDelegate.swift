import AppKit
import Catalog
import Diagnostics
import Launcher
import Persistence
import Settings
import Triggers

/// LaunchpadNative runs as a resident, Dock-icon-less utility (LSUIElement).
/// When bundled as a proper `.app` this is declared via Info.plist; setting the
/// activation policy here keeps the same behavior for an unbundled `swift run`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var scanner: ApplicationScanner?
    private let layoutStore = LayoutStore()
    private let iconCache = IconCache()
    private lazy var launcherWindowController = LauncherWindowController(iconCache: iconCache, layoutStore: layoutStore)
    private lazy var triggerCoordinator = TriggerCoordinator(
        onActivate: { [weak self] in
            self?.launcherWindowController.toggle()
        },
        onPinchClose: { [weak self] in
            self?.launcherWindowController.show()
        },
        onSpreadOpen: { [weak self] in
            self?.launcherWindowController.hide()
        }
    )
    private lazy var settingsWindowController = SettingsWindowController(model: launcherWindowController.model) { [weak self] in
        self?.applyCurrentTriggerSettings() ?? false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        DiagnosticsLog.appHost.info("LaunchpadNative resident host started")

        launcherWindowController.setOnOpenSettings { [weak self] in
            self?.settingsWindowController.show()
        }
        launcherWindowController.setOnRequestUninstall { [weak self] bundleIdentifier in
            self?.settingsWindowController.showUninstallTab(for: bundleIdentifier)
        }

        Task {
            await launcherWindowController.loadGridDocument()

            // Trigger registration and the first show() used to wait for
            // performFullScan() below to finish -- neither actually depends
            // on the catalog being scanned, only on the persisted grid
            // document (already loaded above). Real user report: cold start
            // felt slow, and hot corners/gestures were silently inert until
            // the scan finished (which scales with installed-app count).
            // Moving both here means triggers work and the launcher can
            // appear immediately after launch; updateRecords(_:) below
            // fills in real records moments later exactly the same way the
            // live FSEvents watcher's incremental updates already do, so
            // there's nothing new to reconcile.
            applyCurrentTriggerSettings()

            // Double-clicking the app in Finder is the single most natural
            // thing a first-time user tries — and until now it did nothing
            // visible at all (LSUIElement means no Dock icon, no window
            // unless a trigger fires). Showing the launcher immediately
            // means that first double-click actually shows something right
            // away, instead of silently backgrounding while waiting on a
            // full catalog scan with no discoverable way to know it worked.
            launcherWindowController.show()

            // Debug-only: drives a real search query into the launcher
            // right after it actually shows, so the search-results layout
            // can be screenshotted for verification. This session's
            // Terminal has no Accessibility/GUI-scripting permission, so
            // typing into the field interactively isn't otherwise
            // possible. Deliberately placed here (not a fixed delay from
            // launch) — a flat delay raced the catalog scan and fired
            // before the window ever existed, silently no-op'ing.
            if let query = ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_SEARCH_QUERY"], !query.isEmpty {
                launcherWindowController.debugSetSearchQuery(query)
            }

            // Custom sources (2.13) are only known once the document has
            // loaded, so the scanner is created here rather than at
            // declaration time.
            let customSources = launcherWindowController.model.customSources
                .filter(\.enabled)
                .map { config in
                    ApplicationSource(
                        id: config.id,
                        rootURL: URL(fileURLWithPath: config.rootPath),
                        recursive: config.recursive,
                        priority: config.priority,
                        includeGlobs: config.includeGlobs,
                        excludeGlobs: config.excludeGlobs
                    )
                }
            let scanner = ApplicationScanner(sources: ApplicationSource.standardSources + customSources)
            self.scanner = scanner

            let snapshot = await scanner.performFullScan()
            DiagnosticsLog.appHost.info("Catalog ready: \(snapshot.records.count, privacy: .public) applications")
            launcherWindowController.updateRecords(snapshot.records)
            await scanner.startWatching()

            // Debug-only: drives beginPageDrag/updatePageDrag/endPageDrag
            // with synthetic input (a fast flick) so the state-machine
            // transition can be confirmed via log stream without
            // Accessibility/GUI-scripting permission to perform a real
            // trackpad gesture. Needs the real catalog loaded first (more
            // than one page to drag between), unlike the search-query hook.
            if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_SIMULATE_PAGE_DRAG"] == "1" {
                launcherWindowController.debugSimulatePageDrag()
            }

            for await update in await scanner.updates() {
                launcherWindowController.updateRecords(update.records)
            }
        }

        // Opens Settings on the
        // Uninstall tab directly so it can be verified end-to-end without
        // needing GUI-scripting permission to click the gear button/tab.
        if let bundleID = ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_SHOW_UNINSTALL"], !bundleID.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.settingsWindowController.showUninstallTab(for: bundleID)
            }
        }

    }

    /// Re-applies trigger settings — called at launch and whenever the
    /// Settings window saves a change, since `TriggerCoordinator.apply`
    /// unregisters/reregisters everything idempotently. Returns whether F4
    /// actually activated, so Settings can tell "enabled but not granted
    /// Input Monitoring" apart from "genuinely working."
    @discardableResult
    private func applyCurrentTriggerSettings() -> Bool {
        var settings = launcherWindowController.triggerSettings
        // Debug-only override so triggers can be forced on for verification
        // without going through the Settings window.
        if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_ALL_TRIGGERS"] == "1" {
            settings.f4Enabled = true
            settings.hotCornersEnabled["bottomRight"] = true
            settings.multitouchGestureEnabled = true
        }
        let report = triggerCoordinator.apply(settings)
        DiagnosticsLog.triggers.info(
            "Triggers applied: hotkey=\(report.hotkeyRegistered, privacy: .public) f4=\(report.f4Active, privacy: .public) multitouch=\(report.multitouchActive, privacy: .public)"
        )
        return report.f4Active
    }

    func applicationWillTerminate(_ notification: Notification) {
        triggerCoordinator.stopAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Fires when the already-running app is reopened — a second Finder
    /// double-click, or a Dock icon click if the app is pinned there. Uses
    /// `toggle()`, not `show()`: every other trigger (hot corner, hotkey,
    /// F4) already closes the launcher on a repeat activation while it's
    /// open, and reopening via the icon staying stuck open with no way to
    /// dismiss it that way was a real reported inconsistency — clicking the
    /// icon again should behave the same as every other trigger.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcherWindowController.toggle()
        return true
    }
}
