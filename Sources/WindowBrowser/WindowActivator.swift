import AppKit
import ApplicationServices
import Diagnostics

/// Activates, closes, or minimizes a specific window using the public
/// Accessibility API (`AXUIElement`) — layered per the plan's rule for
/// window activation: app-level focus via the public `NSRunningApplication`,
/// exact-window control via Accessibility, with no private SkyLight
/// ordering call needed for any of this.
///
/// `AXUIElement` doesn't expose a `CGWindowID`/`SCWindow.windowID`, so a
/// window from `WindowEnumerator` is matched to its `AXUIElement` by
/// title+frame — a standard, widely-used technique for this exact gap, not
/// perfectly guaranteed (two windows with an identical title and frame in
/// the same app would be ambiguous) but reliable in the overwhelmingly
/// common case.
public enum WindowActivator {
    /// Requires the user to have granted this app Accessibility permission
    /// (System Settings ▸ Privacy & Security ▸ Accessibility) — confirmed
    /// via `AXIsProcessTrusted()` returning `false` for this unprivileged
    /// dev session, same TCC-identity caveat as Input Monitoring in Phase 5.
    /// When untrusted, activation degrades to app-level focus only.
    public static func activate(_ window: WindowInfo) {
        if let app = NSRunningApplication(processIdentifier: window.ownerProcessID) {
            app.activate()
        }

        guard AXIsProcessTrusted() else {
            DiagnosticsLog.catalog.info("Accessibility not trusted; falling back to app-level activation only for window \(window.id, privacy: .public)")
            return
        }
        guard let axWindow = matchingAXWindow(for: window) else { return }
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
    }

    public static func close(_ window: WindowInfo) {
        guard AXIsProcessTrusted(), let axWindow = matchingAXWindow(for: window) else { return }
        var closeButton: AnyObject?
        guard AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeButton) == .success,
              let button = closeButton else { return }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    public static func minimize(_ window: WindowInfo) {
        guard AXIsProcessTrusted(), let axWindow = matchingAXWindow(for: window) else { return }
        AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    private static func matchingAXWindow(for window: WindowInfo) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.ownerProcessID)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let axWindows = windowsValue as? [AXUIElement] else { return nil }

        for axWindow in axWindows {
            var titleValue: AnyObject?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue)
            let title = titleValue as? String ?? ""

            var positionValue: AnyObject?
            var sizeValue: AnyObject?
            AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionValue)
            AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeValue)

            var origin = CGPoint.zero
            var size = CGSize.zero
            if let positionValue { AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin) }
            if let sizeValue { AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) }

            let frameMatches = abs(origin.x - window.frame.origin.x) < 2
                && abs(origin.y - window.frame.origin.y) < 2
                && abs(size.width - window.frame.width) < 2
                && abs(size.height - window.frame.height) < 2

            if title == window.title || frameMatches {
                return axWindow
            }
        }
        return nil
    }
}
