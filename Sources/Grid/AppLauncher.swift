import AppKit
import Catalog
import Diagnostics

/// Launches an app via the public `NSWorkspace` API. "新規インスタンスで開く"
/// (2.7's context menu item) reuses this with `createsNewApplicationInstance`.
///
/// Deliberately fire-and-forget: the only reporting path is the failure log
/// below. `NSWorkspace.openApplication`'s completion handler runs when the app
/// has *finished launching* (a cold start is anywhere from a few hundred
/// milliseconds to several seconds), not when the request is accepted, so it
/// must never gate UI dismissal — a completion callback wired to the
/// launcher's `hide()` is exactly what left the overlay covering the app the
/// user had just opened. Callers dismiss on the click itself.
public enum AppLauncher {
    @MainActor
    public static func launch(_ record: ApplicationRecord, createsNewInstance: Bool = false) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = createsNewInstance
        NSWorkspace.shared.openApplication(at: record.bundleURL, configuration: configuration) { _, error in
            if let error {
                DiagnosticsLog.launcher.error("Failed to launch \(record.bundleIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
