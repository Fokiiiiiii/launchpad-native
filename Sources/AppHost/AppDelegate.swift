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
        self?.applyCurrentTriggerSettings()
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

            applyCurrentTriggerSettings()

            for await update in await scanner.updates() {
                launcherWindowController.updateRecords(update.records)
            }
        }

        // This env var exists solely so the launcher surface can be manually
        // verified end-to-end without needing a real trigger.
        if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_AUTOSHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.launcherWindowController.show()
            }
        }

        // Same reasoning as LAUNCHPAD_DEBUG_AUTOSHOW: opens Settings on the
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
    /// unregisters/reregisters everything idempotently.
    private func applyCurrentTriggerSettings() {
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        triggerCoordinator.stopAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
