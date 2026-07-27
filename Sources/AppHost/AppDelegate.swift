import AppKit
import Catalog
import Diagnostics
import Launcher
import Onboarding
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
    private lazy var settingsWindowController = SettingsWindowController(
        model: launcherWindowController.model,
        onTriggerSettingsChanged: { [weak self] in self?.applyCurrentTriggerSettings() ?? false },
        onDockVisibilityChanged: { [weak self] hideDock in self?.launcherWindowController.updateDockVisibilityPreference(hideDock) },
        onWillClose: { [weak self] in self?.launcherWindowController.reclaimKeyIfVisible() }
    )
    /// Same floating-over-the-launcher mechanics as `settingsWindowController`
    /// (level, outside-click dismiss) but rebuilt per target app rather than
    /// a singleton-ish always-same-view window — see its own doc comment.
    /// Opening either this or Settings closes the other first (mutual
    /// exclusivity — simpler than solving general multi-panel coexistence
    /// between two independent outside-click monitors, and matches the
    /// reference design, which never shows both at once).
    private lazy var uninstallPanelWindowController = UninstallPanelWindowController(
        iconCache: iconCache,
        onWillClose: { [weak self] in self?.launcherWindowController.reclaimKeyIfVisible() }
    )
    /// Shown instead of the launcher on the very first cold start (see
    /// `OnboardingState`) — the catalog scan/FSEvents watching still run
    /// unconditionally in the background regardless, so by the time
    /// onboarding finishes and the launcher actually appears, the catalog
    /// is already populated exactly like the existing "scan finishes after
    /// show()" pattern. Trigger registration, however, is deliberately
    /// deferred until onboarding actually finishes (see `shouldShowOnboarding`
    /// below) — arming it earlier caused a real, confirmed bug: the
    /// default-on bottom-right hot corner could fire mid-launch if the
    /// cursor already happened to be there, popping the launcher open at
    /// the same time as this wizard.
    private lazy var onboardingWindowController = OnboardingWindowController { [weak self] in
        guard let self else { return }
        applyCurrentTriggerSettings()
        launcherWindowController.show()
    }

    /// `LAUNCHPAD_DEBUG_FORCE_ONBOARDING=1` forces the wizard for
    /// verification without needing to actually clear `OnboardingState`.
    /// Shared by the initial-launch branch and `applicationShouldHandleReopen`
    /// so both agree on whether onboarding still owns this launch.
    private var shouldShowOnboarding: Bool {
        ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_FORCE_ONBOARDING"] == "1" || !OnboardingState.hasCompleted()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        DiagnosticsLog.appHost.info("LaunchpadNative resident host started")

        launcherWindowController.setOnOpenSettings { [weak self] in
            guard let self, launcherWindowController.isVisible else { return }
            uninstallPanelWindowController.close()
            settingsWindowController.show(on: launcherWindowController.currentScreen)
        }

        launcherWindowController.setOnRequestUninstall { [weak self] bundleIdentifier in
            guard let self, launcherWindowController.isVisible,
                  let record = launcherWindowController.model.allRecords.first(where: { $0.bundleIdentifier == bundleIdentifier })
            else { return }
            settingsWindowController.close()
            uninstallPanelWindowController.show(for: record, allRecords: launcherWindowController.model.allRecords, on: launcherWindowController.currentScreen)
        }

        // Round 13 §A: neither panel should ever stay visible once the
        // launcher itself hides — `closeWithoutKeyReclaim()` (not plain
        // `close()`) since there's nothing to reclaim key status onto here
        // and a plain `close()` could steal focus back while the launcher
        // is still mid-fade (see that method's doc comment).
        launcherWindowController.setOnDidHide { [weak self] in
            guard let self else { return }
            settingsWindowController.closeWithoutKeyReclaim()
            uninstallPanelWindowController.closeWithoutKeyReclaim()
        }

        Task {
            await launcherWindowController.loadGridDocument()

            // `NSApp.applicationIconImage` resets to the bundle default on
            // every relaunch — the user's saved AppIconStyle selection must
            // be re-applied here every time, not just when they pick a new
            // one in Settings.
            AppIconStyleApplier.apply(launcherWindowController.model.appIconStyle)

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
            //
            // Double-clicking the app in Finder is the single most natural
            // thing a first-time user tries — and until now it did nothing
            // visible at all (LSUIElement means no Dock icon, no window
            // unless a trigger fires). Showing the launcher immediately
            // means that first double-click actually shows something right
            // away, instead of silently backgrounding while waiting on a
            // full catalog scan with no discoverable way to know it worked.
            // On a genuine first run, the onboarding wizard takes this slot
            // instead, and triggers stay unarmed until it finishes (see
            // `onboardingWindowController`'s doc comment) — otherwise the
            // default-on hot corner could pop the launcher open right on
            // top of the wizard.
            if shouldShowOnboarding {
                onboardingWindowController.show()
            } else {
                applyCurrentTriggerSettings()
                launcherWindowController.show()
            }

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

            // Debug-only: dispatches a *real* synthetic NSEvent mouse down/up
            // at the search field's actual on-screen location, so the exact
            // hit-testing/responder path a real click takes can be examined
            // via log stream. Added because a prior fix (glass background
            // hitTest -> nil) didn't resolve a real user report that
            // clicking the search field still closes the launcher.
            if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_CLICK_SEARCH_FIELD"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.launcherWindowController.debugSimulateSearchFieldClick()
                }
            }

            // Debug-only (Round 13 §E): clicks the search field for real,
            // then dispatches real synthetic keyDown events per character —
            // exercises the real field editor's layout, unlike
            // `LAUNCHPAD_DEBUG_SEARCH_QUERY` above (which bypasses the
            // field editor entirely) — to diagnose "検索欄が入力時だけ
            // おかしい". Combine with `LAUNCHPAD_DEBUG_SEARCH_FIELD_EDITING=1`
            // to also log the field editor's geometry at each keystroke.
            if let text = ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_TYPE_SEARCH_FIELD"], !text.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.launcherWindowController.debugSimulateSearchFieldTyping(text)
                }
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
            // with synthetic input so the state-machine transition can be
            // confirmed via log stream without Accessibility/GUI-scripting
            // permission to perform a real trackpad gesture. Needs the real
            // catalog loaded first (more than one page to drag between).
            // "commit" or "abort" selects which path to simulate — both
            // matter given this feature's history.
            if let mode = ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_SIMULATE_PAGE_DRAG"] {
                launcherWindowController.debugSimulatePageDrag(commit: mode != "abort")
            }

            // Debug-only: drives the custom item-drag state machine
            // (lift/reorder/folder-creation) with synthetic points, same
            // reasoning as LAUNCHPAD_DEBUG_SIMULATE_PAGE_DRAG above —
            // "reorder" or "folder" selects which outcome to simulate.
            if let mode = ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_SIMULATE_ITEM_DRAG"] {
                launcherWindowController.debugSimulateItemDrag(mode: mode)
            }

            for await update in await scanner.updates() {
                launcherWindowController.updateRecords(update.records)
            }
        }

        // Debug-only: opens Settings, then closes it, then logs whether the
        // launcher window regained key status — exercises the fix for a
        // real, confirmed regression (user report: the search field stopped
        // accepting clicks/keyboard input after closing Settings).
        // `LauncherWindow` is a `.nonactivatingPanel`; AppKit's automatic
        // "hand key status to the next window" behavior doesn't pick those
        // back up the way it would an ordinary window when the window that
        // took key status over (Settings) closes, so
        // `SettingsWindowController.onWillClose` ->
        // `LauncherWindowController.reclaimKeyIfVisible()` now does it
        // explicitly. No Accessibility/GUI-scripting permission is needed
        // for this, since nothing here simulates an actual mouse click.
        if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_SETTINGS_KEY_RECLAIM"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.settingsWindowController.show(on: self?.launcherWindowController.currentScreen)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.settingsWindowController.debugClose()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        let isKey = self?.launcherWindowController.debugIsWindowKey() ?? false
                        DiagnosticsLog.launcher.info("debug settings-key-reclaim: launcher isKeyWindow=\(isKey, privacy: .public) after Settings closed")
                    }
                }
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
        if shouldShowOnboarding {
            onboardingWindowController.show()
        } else {
            launcherWindowController.toggle()
        }
        return true
    }
}
