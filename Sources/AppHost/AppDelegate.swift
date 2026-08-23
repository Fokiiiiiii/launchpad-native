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
        installCrashReporting()

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

            let configuredSources = applicationSources()
            let scanner = ApplicationScanner(sources: configuredSources)
            self.scanner = scanner
            let cachedRecords = CatalogSnapshotStore.load(sources: configuredSources)
            await scanner.restoreCachedRecords(cachedRecords)
            if !cachedRecords.isEmpty {
                // Not authoritative: this snapshot exists to get a first frame
                // up quickly and can lag the real disk state, so it must not
                // drive removals. `performFullScan()` below reconciles again
                // with the authoritative set.
                launcherWindowController.updateRecords(cachedRecords, isAuthoritative: false)
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

            if let query = ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_SEARCH_QUERY"], !query.isEmpty {
                launcherWindowController.debugSetSearchQuery(query)
            }

            if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_CLICK_SEARCH_FIELD"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.launcherWindowController.debugSimulateSearchFieldClick()
                }
            }

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

            if let mode = ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_SIMULATE_ITEM_DRAG"] {
                launcherWindowController.debugSimulateItemDrag(mode: mode)
            }

            if let ordinal = ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_OPEN_FIRST_FOLDER"].flatMap(Int.init) {
                launcherWindowController.debugOpenFolder(ordinal: ordinal)
            }

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
        TriggerSettingsPolicy.isGestureConflictFingerSwitch(from: previous, to: candidate)
    }

    private func normalizedTriggerSettings(_ requested: TriggerSettings) -> TriggerSettings {
        TriggerSettingsPolicy.normalized(
            requested,
            // Debug-only override so triggers can be forced on for verification
            // without going through the Settings window.
            forceAllTriggers: ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_ALL_TRIGGERS"] == "1"
        )
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
        let durableSettings = TriggerSettingsPolicy.durableRollbackSettings(
            previous: previous,
            rollbackFailed: rollbackFailed,
            candidateBackup: candidateBackup,
            currentBackup: model.triggerSettings.gestureConflictBackup
        )
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
        // Last thing: anything that skips this leaves the session flag set, and
        // the next launch reports the run as having ended unexpectedly.
        CrashSentinel.endSession()
    }

    /// Two cheap signals that something went wrong, neither of which needs a
    /// third-party service or a signal handler.
    ///
    /// macOS writes its own crash reports, but nothing in them reaches the app:
    /// a build that crashes for some users looks the same from the inside as
    /// one that does not. This records that a run failed to shut down, and logs
    /// uncaught Objective-C exceptions — the AppKit-originated failures that
    /// would otherwise vanish with the process.
    private func installCrashReporting() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        CrashSentinel.beginSession(version: version)
        NSSetUncaughtExceptionHandler { exception in
            // Deliberately minimal: this runs while the process is already on
            // its way down, so it logs and does nothing else.
            DiagnosticsLog.appHost.fault(
                "Uncaught exception \(exception.name.rawValue, privacy: .public): \(exception.reason ?? "no reason", privacy: .public)"
            )
        }
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
