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

    /// Whether the window was closed. False when it could not be told apart from
    /// another, or Accessibility refused — the caller must not show it as gone.
    @discardableResult
    public static func close(_ window: WindowInfo) -> Bool {
        guard AXIsProcessTrusted(), let axWindow = matchingAXWindow(for: window) else { return false }
        var closeButton: AnyObject?
        guard AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeButton) == .success,
              let closeButton,
              CFGetTypeID(closeButton) == AXUIElementGetTypeID() else {
            DiagnosticsLog.catalog.error("Accessibility returned an invalid close button for window \(window.id, privacy: .public)")
            return false
        }
        let button = unsafeDowncast(closeButton, to: AXUIElement.self)
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    @discardableResult
    public static func minimize(_ window: WindowInfo) -> Bool {
        guard AXIsProcessTrusted(), let axWindow = matchingAXWindow(for: window) else { return false }
        return AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
    }

    private static func matchingAXWindow(for window: WindowInfo) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.ownerProcessID)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let axWindows = windowsValue as? [AnyObject] else { return nil }

        var elements: [AXUIElement] = []
        var candidates: [Candidate] = []
        for axWindow in axWindows {
            guard CFGetTypeID(axWindow) == AXUIElementGetTypeID() else {
                DiagnosticsLog.catalog.error("Accessibility returned an invalid window element for process \(window.ownerProcessID, privacy: .public)")
                continue
            }
            let windowElement = unsafeDowncast(axWindow, to: AXUIElement.self)

            var titleValue: AnyObject?
            AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleValue)
            var positionValue: AnyObject?
            var sizeValue: AnyObject?
            AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionValue)
            AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeValue)

            elements.append(windowElement)
            candidates.append(Candidate(
                title: titleValue as? String ?? "",
                origin: point(from: positionValue),
                size: size(from: sizeValue)
            ))
        }
        guard let index = bestMatch(for: window, among: candidates) else {
            DiagnosticsLog.catalog.info("No single window of process \(window.ownerProcessID, privacy: .public) matches window \(window.id, privacy: .public); not acting on any")
            return nil
        }
        return elements[index]
    }

    /// What Accessibility says about one window of the app.
    struct Candidate: Equatable {
        let title: String
        let origin: CGPoint?
        let size: CGSize?
    }

    /// The one candidate that is `window`, or nil when that cannot be said.
    ///
    /// Accessibility exposes no window number, so a window is recognised by its
    /// title and frame. Taking whichever matched *either* first meant a close
    /// or a minimize could land on another window of the same app — same
    /// title, or just the same spot. So: both must agree if any candidate
    /// satisfies both; failing that, one of them must single out exactly one
    /// window (a title edited since the list was made, a window moved). Two
    /// candidates that fit equally well are not guessed between.
    static func bestMatch(for window: WindowInfo, among candidates: [Candidate]) -> Int? {
        func titleMatches(_ candidate: Candidate) -> Bool { candidate.title == window.title }
        func frameMatches(_ candidate: Candidate) -> Bool {
            matchesFrame(expected: window.frame, origin: candidate.origin, size: candidate.size)
        }
        let tiers: [(Candidate) -> Bool] = [
            { titleMatches($0) && frameMatches($0) },
            { frameMatches($0) },
            // An empty title identifies nothing: untitled windows all share it.
            { !window.title.isEmpty && titleMatches($0) },
        ]
        for tier in tiers {
            let matching = candidates.indices.filter { tier(candidates[$0]) }
            if matching.count == 1 { return matching[0] }
            if matching.count > 1 { return nil }
        }
        return nil
    }

    static func matchesFrame(expected: CGRect, origin: CGPoint?, size: CGSize?, tolerance: CGFloat = 2) -> Bool {
        guard let origin, let size else { return false }
        return abs(origin.x - expected.origin.x) < tolerance
            && abs(origin.y - expected.origin.y) < tolerance
            && abs(size.width - expected.width) < tolerance
            && abs(size.height - expected.height) < tolerance
    }

    private static func point(from value: AnyObject?) -> CGPoint? {
        guard let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func size(from value: AnyObject?) -> CGSize? {
        guard let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }
}
