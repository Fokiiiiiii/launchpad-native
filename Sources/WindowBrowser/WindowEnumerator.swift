import Diagnostics
import Foundation
import ScreenCaptureKit

/// Enumerates real, on-screen windows via `ScreenCaptureKit`'s
/// `SCShareableContent` — fully public (macOS 12.3+), confirmed working live
/// on this machine including inside a real `NSApplication` context (a bare
/// command-line probe crashed with a `CGS_REQUIRE_INIT` assertion; this
/// app's normal AppKit run loop doesn't have that problem). No private
/// SkyLight enumeration API was needed for this — see
/// `ReverseEngineering/Contracts/skylight.md` for why Space *association*
/// still needs the private API as a Tier 2 addition, which this module
/// doesn't implement yet (see the type doc comment on `WindowActivator`).
public enum WindowEnumerator {
    /// Windows belonging to any known system-owned surface (menu bar, Dock,
    /// window manager, notification/control center) plus this app's own
    /// bundle identifier, so the launcher never lists itself.
    public static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "com.apple.systemuiserver",
        "com.launchpadnative.app"
    ]

    public static func allUserWindows() async -> [WindowInfo] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let all = content.windows.map { window -> WindowInfo in
                WindowInfo(
                    id: Int(window.windowID),
                    title: window.title ?? "",
                    ownerBundleIdentifier: window.owningApplication?.bundleIdentifier,
                    ownerProcessID: window.owningApplication?.processID ?? 0,
                    frame: window.frame,
                    isOnScreen: window.isOnScreen
                )
            }
            return all.filter { WindowFiltering.isUserWindow($0, excludingBundleIdentifiers: excludedBundleIdentifiers) }
        } catch {
            DiagnosticsLog.catalog.error("SCShareableContent enumeration failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    public static func windows(forBundleIdentifier bundleIdentifier: String) async -> [WindowInfo] {
        WindowFiltering.windows(for: bundleIdentifier, in: await allUserWindows())
    }
}
