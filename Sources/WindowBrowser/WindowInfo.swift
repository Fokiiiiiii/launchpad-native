import Foundation

/// One user-facing window, decoupled from `ScreenCaptureKit`'s `SCWindow` so
/// the rest of the app (and tests) don't need to link against it directly.
public struct WindowInfo: Sendable, Equatable, Identifiable {
    public let id: Int
    public let title: String
    public let ownerBundleIdentifier: String?
    public let ownerProcessID: Int32
    public let frame: CGRect
    public let isOnScreen: Bool

    public init(id: Int, title: String, ownerBundleIdentifier: String?, ownerProcessID: Int32, frame: CGRect, isOnScreen: Bool) {
        self.id = id
        self.title = title
        self.ownerBundleIdentifier = ownerBundleIdentifier
        self.ownerProcessID = ownerProcessID
        self.frame = frame
        self.isOnScreen = isOnScreen
    }
}

/// Pure filtering logic, kept free of ScreenCaptureKit so it's unit-testable
/// without a real window server session.
public enum WindowFiltering {
    /// Excludes the kind of window that isn't a real user document/app
    /// window: menu bar extras, tiny keepalive/lifecycle helper windows,
    /// and this launcher's own overlay.
    public static func isUserWindow(_ window: WindowInfo, excludingBundleIdentifiers excluded: Set<String>) -> Bool {
        guard window.isOnScreen else { return false }
        if let bundleID = window.ownerBundleIdentifier, excluded.contains(bundleID) {
            return false
        }
        // A real document/app window is essentially never this small —
        // menu bar item backing windows, lifecycle keepalive windows, and
        // similar non-user surfaces commonly are.
        guard window.frame.width >= 100, window.frame.height >= 60 else { return false }
        return true
    }

    public static func windows(for bundleIdentifier: String, in all: [WindowInfo]) -> [WindowInfo] {
        all.filter { $0.ownerBundleIdentifier == bundleIdentifier }
    }
}
