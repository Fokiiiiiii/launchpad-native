import AppKit
import Catalog
import Diagnostics
import Launcher
import Localization
import Onboarding
import Persistence
import Settings
import Triggers
import WhatsNew

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
            self?.openLauncherFromMultitouch()
        },
        onSpreadOpen: { [weak self] in
            self?.launcherWindowController.hide()
        }
    )
    private lazy var settingsWindowController: SettingsWindowController = SettingsWindowController(
        model: launcherWindowController.model,
        onTriggerSettingsChanged: { [weak self] settings in
            guard let self else { return .failed }
            return await self.applyCurrentTriggerSettings(settings)
        },
        onDockVisibilityChanged: { [weak self] hideDock in self?.launcherWindowController.updateDockVisibilityPreference(hideDock) },
        onShowsMenuBarIconChanged: { [weak self] visible in self?.menuBarIconController.setVisible(visible) },
        onAppIconStyleChanged: { [weak self] _ in self?.menuBarIconController.refreshIcon() },
        onShowsHiddenAppsInSearchChanged: { [weak self] in self?.launcherWindowController.refreshSearchableRecords() },
        onMenuBarApplicationsChanged: { [weak self] in self?.launcherWindowController.refreshSearchableRecords() },
        onBackgroundSettingsChanged: { [weak self] in
            guard let self else { return }
            let model = launcherWindowController.model
            launcherWindowController.updateBackgroundSettings(
                mode: model.backgroundMode,
                materialIntensity: model.glassMaterialIntensity,
                blursWallpaper: model.blursWallpaper
            )
        },
        onCustomSourcesChanged: { [weak self] in
            self?.refreshScannerSources()
        },
        onWillClose: { [weak self] in self?.launcherWindowController.reclaimKeyIfVisible() }
    )
    private lazy var menuBarIconController: MenuBarIconController = MenuBarIconController(
        onOpenLauncher: { [weak self] in self?.launcherWindowController.show() },
        onOpenSettings: { [weak self] in
            guard let self else { return }
            launcherWindowController.show()
            settingsWindowController.show(on: launcherWindowController.currentScreen)
        }
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
        Task { @MainActor in
            _ = await self.applyCurrentTriggerSettingsAndPersist(launcherWindowController.triggerSettings)
            launcherWindowController.show()
        }
    }
    /// Same floating-over-the-launcher mechanics as `settingsWindowController`
    /// — see `WhatsNewWindowController`'s own doc comment for why it follows
    /// that pattern rather than `onboardingWindowController`'s simpler one.
    private lazy var whatsNewWindowController = WhatsNewWindowController { [weak self] in
        self?.launcherWindowController.reclaimKeyIfVisible()
    }

    /// `LAUNCHPAD_DEBUG_FORCE_ONBOARDING=1` forces the wizard for
    /// verification without needing to actually clear `OnboardingState`.
    /// Shared by the initial-launch branch and `applicationShouldHandleReopen`
    /// so both agree on whether onboarding still owns this launch.
    private var shouldShowOnboarding: Bool {
        ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_FORCE_ONBOARDING"] == "1" || !OnboardingState.hasCompleted()
    }

    private func applicationSources() -> [ApplicationSource] {
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
        return ApplicationSource.standardSources + customSources
    }

    private func refreshScannerSources() {
        guard let scanner else { return }
        let sources = applicationSources()
        Task {
            await scanner.replaceSources(sources)
        }
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
            whatsNewWindowController.closeWithoutKeyReclaim()
        }

        Task {
            await launcherWindowController.loadGridDocument()

            // `NSApp.applicationIconImage` resets to the bundle default on
            // every relaunch — the user's saved AppIconStyle selection must
            // be re-applied here every time, not just when they pick a new
            // one in Settings.
            AppIconStyleApplier.apply(launcherWindowController.model.appIconStyle)
            menuBarIconController.setVisible(launcherWindowController.model.showsMenuBarIcon)

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
            // Restore the bounded last-known-good catalog before the first
            // frame. This path only reads JSON and cheap filesystem metadata;
            // the expensive Bundle/Security work remains in the background scan.
            let configuredSources = applicationSources()
            let scanner = ApplicationScanner(sources: configuredSources)
            self.scanner = scanner
            let cachedRecords = CatalogSnapshotStore.load(sources: configuredSources)
            await scanner.restoreCachedRecords(cachedRecords)
            if !cachedRecords.isEmpty {
                launcherWindowController.updateRecords(cachedRecords)
            }
            await scanner.startWatching()

            if shouldShowOnboarding {
                onboardingWindowController.show()
            } else {
                _ = await applyCurrentTriggerSettingsAndPersist(launcherWindowController.triggerSettings)
                launcherWindowController.show()
                presentWhatsNewIfNeeded()

                if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_SHOW_SETTINGS"] == "1" {
                    whatsNewWindowController.closeWithoutKeyReclaim()
                    settingsWindowController.show(on: launcherWindowController.currentScreen)
                }
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

            // Reconcile the live catalog after the first frame. The scan runs
            // on the Catalog actor from a utility task, so Bundle metadata and
            // code-signing inspection never block the launcher window.
            Task.detached(priority: .utility) { [scanner, configuredSources] in
                let snapshot = await scanner.performFullScan()
                CatalogSnapshotStore.save(records: snapshot.records, sources: configuredSources)
                DiagnosticsLog.appHost.info(
                    "Catalog ready: \(snapshot.records.count, privacy: .public) applications"
                )
            }

            // Debug-only: drives beginPageDrag/updatePageDrag/endPageDrag
            // with synthetic input so the state-machine transition can be
            // confirmed via log stream without Accessibility/GUI-scripting
            // permission to perform a real trackpad gesture. Needs the real
            // catalog loaded first (more than one page to drag between).
            // "commit" or "abort" selects which path to simulate; "rapid"
            // fires a second commit ~150ms after the first (well inside the
            // up-to-~1s settle window) — a real, confirmed regression
            // ("連続でページをスワイプした時にページが送られない時があ
            // る") where a swipe starting during a still-settling previous
            // one was silently dropped. Kept permanently (not a one-off
            // test) since this exact class of bug — a new gesture arriving
            // before the previous one's async settle completes — has a real
            // history of resurfacing in this file.
            if let mode = ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_SIMULATE_PAGE_DRAG"] {
                if mode == "rapid" {
                    launcherWindowController.debugSimulatePageDrag(commit: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak launcherWindowController] in
                        launcherWindowController?.debugSimulatePageDrag(commit: true)
                    }
                } else {
                    launcherWindowController.debugSimulatePageDrag(commit: mode != "abort")
                }
            }

            // Debug-only: drives the custom item-drag state machine
            // (lift/reorder/folder-creation) with synthetic points, same
            // reasoning as LAUNCHPAD_DEBUG_SIMULATE_PAGE_DRAG above —
            // "reorder" or "folder" selects which outcome to simulate.
            if let mode = ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_SIMULATE_ITEM_DRAG"] {
                launcherWindowController.debugSimulateItemDrag(mode: mode)
            }

            // Debug-only: opens the first folder found on the current page,
            // exercising the new full-screen overlay's view construction
            // without needing a real click.
            if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_OPEN_FIRST_FOLDER"] == "1" {
                launcherWindowController.debugOpenFirstFolder()
            }

            // Debug-only: opens the Uninstall panel against
            // Scripts/build-uninstall-fixture.sh's throwaway fixture app —
            // never a real installed app — so the panel's section/row
            // rendering can be checked via log stream without needing a
            // real right-click-menu interaction (this session has no
            // Accessibility/GUI-scripting permission to perform one).
            if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_SHOW_UNINSTALL"] == "1" {
                let fixtureURL = URL(fileURLWithPath: NSHomeDirectory() + "/.cache/launchpad-native/fixtures/UninstallFixture.app")
                let bundleID = "com.launchpadnative.uninstallfixture"
                let record = ApplicationRecord(
                    id: StableAppID(bundleURL: fixtureURL, bundleIdentifier: bundleID, teamIdentifier: nil),
                    bundleIdentifier: bundleID,
                    bundleURL: fixtureURL,
                    executableURL: nil,
                    displayName: "Uninstall Fixture",
                    originalDisplayName: "Uninstall Fixture",
                    bundleVersion: "1.0",
                    teamIdentifier: nil,
                    category: nil,
                    sourceID: "debug",
                    isSystemProtected: false,
                    isBackgroundOnly: false,
                    iconCacheKey: bundleID,
                    canLaunch: false,
                    canOpenNewInstance: false,
                    lastSeenModificationDate: Date(timeIntervalSince1970: 0)
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self else { return }
                    DiagnosticsLog.appHost.info("LAUNCHPAD_DEBUG_SHOW_UNINSTALL: showing panel for fixture record")
                    self.uninstallPanelWindowController.show(for: record, allRecords: [record], on: self.launcherWindowController.currentScreen)
                }
            }

            var skippedRestoredSnapshot = false
            let restoredIDs = Set(cachedRecords.map { $0.id })
            for await update in await scanner.updates() {
                if !skippedRestoredSnapshot {
                    skippedRestoredSnapshot = true
                    if Set(update.records.map { $0.id }) == restoredIDs {
                        continue
                    }
                }
                launcherWindowController.updateRecords(update.records)
            }
        }

        // Debug-only: opens Settings, then closes it, then logs whether the
        // launcher window regained key status — exercises the fix for a
        // real, confirmed regression (user report: the search field stopped
        // accepting clicks/keyboard input after closing Settings).
        // The launcher is a same-desktop overlay; AppKit's automatic
        // "hand key status to the next window" behavior does not always pick
        // it back up after the window that
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

    /// Applies a candidate trigger configuration as a transaction: capture
    /// and persist the restore point before mutating CFPreferences, then
    /// persist the verified result. Finger-count transitions first restore the
    /// old point, capture the new point, and only then disable the new key.
    /// Any failure restores both the external preference and this model to the
    /// prior settings before reporting failure to Settings.
    @discardableResult
    private func applyCurrentTriggerSettings(_ requested: TriggerSettings) async -> TriggerSettingsApplyResult {
        let model = launcherWindowController.model
        let previous = model.triggerSettings
        let runtimeSettings = normalizedTriggerSettings(requested)
        let isFingerSwitch = isGestureConflictFingerSwitch(
            from: previous,
            to: runtimeSettings
        )

        let preparedRuntimeSettings: TriggerSettings
        if isFingerSwitch {
            // Restore the old key before reading the new key. This makes the
            // next capture reflect the true pre-disable value for the target
            // finger count, rather than mixing two active transitions.
            guard triggerCoordinator.restoreGestureConflictForTransition(
                fallback: previous.gestureConflictBackup
            ) else {
                DiagnosticsLog.persistence.error("Existing trigger restore point could not be restored before finger switch")
                return .failed
            }
            guard let prepared = triggerCoordinator.prepareRestorePoint(for: runtimeSettings) else {
                await rollbackTriggerSettings(to: previous)
                DiagnosticsLog.persistence.error("New trigger restore point could not be prepared after finger switch restore")
                return .failed
            }
            preparedRuntimeSettings = prepared
        } else {
            guard let prepared = triggerCoordinator.prepareRestorePoint(for: runtimeSettings) else {
                DiagnosticsLog.persistence.error("Trigger settings restore point could not be prepared")
                return .failed
            }
            preparedRuntimeSettings = prepared
        }

        // Debug overrides affect runtime registration only. Keep the user's
        // requested trigger values as the durable source of truth while
        // carrying over the restore point captured for the runtime candidate.
        var prepared = requested
        prepared.gestureConflictPreventionEnabled = runtimeSettings.gestureConflictPreventionEnabled
        prepared.gestureConflictBackup = preparedRuntimeSettings.gestureConflictBackup

        if isFingerSwitch {
            // The old restore point was kept durable until the old key was
            // restored above. Persist the new restore point before the new
            // key is disabled, so a crash cannot lose either transition's
            // source value before the side effect begins.
            model.updateTriggerSettings(prepared)
            guard await model.saveResult() else {
                await rollbackTriggerSettings(to: previous)
                DiagnosticsLog.persistence.error("New trigger restore point could not be persisted before finger switch disable")
                return .failed
            }
        } else {
            // For initial enable, same-finger re-apply, and disable/restore,
            // the restore point is intentionally durable before `apply`,
            // because that call can change another app's CFPreferences
            // immediately.
            model.updateTriggerSettings(prepared)
            guard await model.saveResult() else {
                model.updateTriggerSettings(previous)
                DiagnosticsLog.persistence.error("Trigger settings restore point could not be persisted")
                return .failed
            }
        }

        let runtimeResult = applyCurrentTriggerSettingsRuntime(preparedRuntimeSettings)
        let result: TriggerSettingsApplyResult
        if isFingerSwitch, runtimeResult.gestureConflictStatus == .unchanged {
            // The transition was split into an explicit restore and a
            // pre-captured disable, so the coordinator's final phase is
            // intentionally `.unchanged`; preserve the public status that a
            // new conflict backup was applied for Settings/reporting.
            result = TriggerSettingsApplyResult(
                f4Active: runtimeResult.f4Active,
                multitouchActive: runtimeResult.multitouchActive,
                multitouchEventArbitrationActive: runtimeResult.multitouchEventArbitrationActive,
                gestureConflictStatus: .applied,
                gestureConflictBackup: runtimeResult.gestureConflictBackup
            )
        } else {
            result = runtimeResult
        }
        guard result.gestureConflictStatus != .failed else {
            await rollbackTriggerSettings(
                to: previous,
                preservingBackup: prepared.gestureConflictBackup
            )
            return .failed
        }

        var persisted = prepared
        switch result.gestureConflictStatus {
        case .restored:
            persisted.gestureConflictBackup = nil
        case .applied, .unchanged:
            persisted.gestureConflictBackup = result.gestureConflictBackup
        case .failed:
            // Guarded above; keep the switch exhaustive if a new status is
            // added later.
            await rollbackTriggerSettings(
                to: previous,
                preservingBackup: prepared.gestureConflictBackup
            )
            return .failed
        }
        model.updateTriggerSettings(persisted)
        guard await model.saveResult() else {
            DiagnosticsLog.persistence.error("Trigger settings result could not be persisted; restoring prior state")
            await rollbackTriggerSettings(
                to: previous,
                preservingBackup: persisted.gestureConflictBackup
            )
            return .failed
        }
        return result
    }

    private func isGestureConflictFingerSwitch(
        from previous: TriggerSettings,
        to candidate: TriggerSettings
    ) -> Bool {
        guard previous.multitouchGestureEnabled,
              candidate.multitouchGestureEnabled,
              let previousBackup = previous.gestureConflictBackup else {
            return false
        }
        return previousBackup.fingerCount != candidate.multitouchFingerCount
    }

    private func normalizedTriggerSettings(_ requested: TriggerSettings) -> TriggerSettings {
        var settings = requested
        // Debug-only override so triggers can be forced on for verification
        // without going through the Settings window.
        if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_ALL_TRIGGERS"] == "1" {
            settings.f4Enabled = true
            settings.hotCornersEnabled["bottomRight"] = true
            settings.multitouchGestureEnabled = true
        }
        // The raw MultitouchSupport listener is passive. A multitouch
        // trigger therefore owns the matching macOS conflict policy as one
        // transaction; a stale persisted opt-out lets the system consume the
        // same physical gesture first.
        settings.gestureConflictPreventionEnabled = settings.multitouchGestureEnabled
        return settings
    }

    private func openLauncherFromMultitouch() {
        if !triggerCoordinator.reinforceGestureConflict() {
            DiagnosticsLog.triggers.error("Multitouch activation could not reassert the macOS conflict policy")
        }
        launcherWindowController.show()
    }

    @discardableResult
    private func applyCurrentTriggerSettingsRuntime(_ settings: TriggerSettings) -> TriggerSettingsApplyResult {
        let report = triggerCoordinator.apply(settings)
        DiagnosticsLog.triggers.info(
            "Triggers applied: hotkey=\(report.hotkeyRegistered, privacy: .public) f4=\(report.f4Active, privacy: .public) multitouch=\(report.multitouchActive, privacy: .public) arbitration=\(report.multitouchEventArbitrationActive, privacy: .public) conflict=\(String(describing: report.gestureConflictUpdate), privacy: .public)"
        )
        let conflictStatus: GestureConflictApplyStatus
        let backup: GestureConflictBackup?
        switch report.gestureConflictUpdate {
        case .unchanged:
            conflictStatus = .unchanged
            backup = settings.gestureConflictBackup
        case .cleared:
            conflictStatus = .restored
            backup = nil
        case .updated(let newBackup):
            conflictStatus = .applied
            backup = newBackup
        case .failed:
            conflictStatus = .failed
            backup = settings.gestureConflictBackup
        }
        return TriggerSettingsApplyResult(
            f4Active: report.f4Active,
            multitouchActive: report.multitouchActive,
            multitouchEventArbitrationActive: report.multitouchEventArbitrationActive,
            gestureConflictStatus: conflictStatus,
            gestureConflictBackup: backup
        )
    }

    private func rollbackTriggerSettings(
        to previous: TriggerSettings,
        preservingBackup candidateBackup: GestureConflictBackup? = nil
    ) async {
        let rollbackResult = applyCurrentTriggerSettingsRuntime(previous)
        let rollbackFailed = rollbackResult.gestureConflictStatus == .failed
        if rollbackFailed {
            DiagnosticsLog.persistence.error("Trigger settings external rollback failed")
        }
        let model = launcherWindowController.model
        var durableSettings = previous
        if rollbackFailed {
            // Never erase the only restore point while CFPreferences is in an
            // indeterminate/partial state. Keeping it on disk lets the next
            // apply retry the exact values instead of treating the current
            // zero as the user's original preference.
            durableSettings.gestureConflictBackup =
                candidateBackup ?? model.triggerSettings.gestureConflictBackup ?? previous.gestureConflictBackup
        }
        model.updateTriggerSettings(durableSettings)
        guard await model.saveResult() else {
            DiagnosticsLog.persistence.error("Trigger settings model rollback could not be persisted")
            return
        }
    }

    /// Startup has no SettingsViewModel to commit a verified restore point.
    /// Persist the runtime result before showing the launcher so a crash after
    /// a successful CFPreferences write does not discard the backup.
    private func applyCurrentTriggerSettingsAndPersist(_ requested: TriggerSettings) async -> TriggerSettingsApplyResult {
        await applyCurrentTriggerSettings(requested)
    }

    /// Shows the "What's New" panel once per version bump — never on a
    /// genuine first run (this is only called from the non-onboarding
    /// branch above; a first-time user has nothing "new" to compare
    /// against) and never more than once per launch (this only runs from
    /// `applicationDidFinishLaunching`, not from every subsequent
    /// hotkey-triggered `show()`).
    private func presentWhatsNewIfNeeded() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        guard WhatsNewState.lastShownVersion() != currentVersion else { return }
        whatsNewWindowController.show(
            version: currentVersion,
            features: [
                WhatsNewFeature(
                    symbolName: "square.grid.2x2.fill",
                    title: L10n.whatsNewFeatureFolderReorderTitle,
                    body: L10n.whatsNewFeatureFolderReorderBody
                ),
                WhatsNewFeature(
                    symbolName: "hand.draw",
                    title: L10n.whatsNewFeatureGestureConflictTitle,
                    body: L10n.whatsNewFeatureGestureConflictBody
                ),
                WhatsNewFeature(
                    symbolName: "rectangle.expand.vertical",
                    title: L10n.whatsNewFeatureFolderFullScreenTitle,
                    body: L10n.whatsNewFeatureFolderFullScreenBody
                )
            ],
            on: launcherWindowController.currentScreen
        )
        WhatsNewState.markShown(version: currentVersion)
    }

    func applicationWillTerminate(_ notification: Notification) {
        launcherWindowController.prepareForTermination()
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
