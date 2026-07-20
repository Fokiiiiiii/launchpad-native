import AppKit
import Catalog
import Diagnostics
import Launcher
import Persistence
import Triggers

/// LaunchpadNative runs as a resident, Dock-icon-less utility (LSUIElement).
/// When bundled as a proper `.app` this is declared via Info.plist; setting the
/// activation policy here keeps the same behavior for an unbundled `swift run`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let scanner = ApplicationScanner()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        DiagnosticsLog.appHost.info("LaunchpadNative resident host started")

        Task {
            await launcherWindowController.loadGridDocument()
            let snapshot = await scanner.performFullScan()
            DiagnosticsLog.appHost.info("Catalog ready: \(snapshot.records.count, privacy: .public) applications")
            launcherWindowController.updateRecords(snapshot.records)
            await scanner.startWatching()

            var settings = launcherWindowController.triggerSettings
            // Debug-only override so Phase 5's triggers can be verified live
            // on this machine without needing a Settings UI (Phase 6) yet to
            // opt in — persisted user settings are untouched otherwise.
            if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_ALL_TRIGGERS"] == "1" {
                settings.f4Enabled = true
                settings.hotCornersEnabled["bottomRight"] = true
                settings.multitouchGestureEnabled = true
            }
            let report = triggerCoordinator.apply(settings)
            DiagnosticsLog.triggers.info(
                "Triggers applied: hotkey=\(report.hotkeyRegistered, privacy: .public) f4=\(report.f4Active, privacy: .public) multitouch=\(report.multitouchActive, privacy: .public)"
            )

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        triggerCoordinator.stopAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
