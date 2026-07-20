import AppKit
import Catalog
import Diagnostics
import Persistence

/// LaunchpadNative runs as a resident, Dock-icon-less utility (LSUIElement).
/// When bundled as a proper `.app` this is declared via Info.plist; setting the
/// activation policy here keeps the same behavior for an unbundled `swift run`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let scanner = ApplicationScanner()
    private let layoutStore = LayoutStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        DiagnosticsLog.appHost.info("LaunchpadNative resident host started")

        Task {
            _ = await layoutStore.load()
            let snapshot = await scanner.performFullScan()
            DiagnosticsLog.appHost.info("Catalog ready: \(snapshot.records.count, privacy: .public) applications")
            await scanner.startWatching()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
