import AppKit
import Catalog
import Diagnostics
import Launcher
import Persistence

/// LaunchpadNative runs as a resident, Dock-icon-less utility (LSUIElement).
/// When bundled as a proper `.app` this is declared via Info.plist; setting the
/// activation policy here keeps the same behavior for an unbundled `swift run`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let scanner = ApplicationScanner()
    private let layoutStore = LayoutStore()
    private let iconCache = IconCache()
    private lazy var launcherWindowController = LauncherWindowController(iconCache: iconCache)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        DiagnosticsLog.appHost.info("LaunchpadNative resident host started")

        Task {
            _ = await layoutStore.load()
            let snapshot = await scanner.performFullScan()
            DiagnosticsLog.appHost.info("Catalog ready: \(snapshot.records.count, privacy: .public) applications")
            launcherWindowController.updateRecords(snapshot.records)
            await scanner.startWatching()

            for await update in await scanner.updates() {
                launcherWindowController.updateRecords(update.records)
            }
        }

        // Global triggers (hotkey/hot corner/F4/gesture) land in Phase 5.
        // This env var exists solely so the launcher surface can be manually
        // verified end-to-end before those triggers are wired up.
        if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_AUTOSHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.launcherWindowController.show()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
