import AppKit
import Catalog
import Diagnostics

/// Launches an app via the public `NSWorkspace` API. "新規インスタンスで開く"
/// (2.7's context menu item) reuses this with `createsNewApplicationInstance`.
public enum AppLauncher {
    @MainActor
    public static func launch(_ record: ApplicationRecord, createsNewInstance: Bool = false, completion: (@MainActor () -> Void)? = nil) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = createsNewInstance
        NSWorkspace.shared.openApplication(at: record.bundleURL, configuration: configuration) { _, error in
            if let error {
                DiagnosticsLog.launcher.error("Failed to launch \(record.bundleIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                completion?()
            }
        }
    }
}
