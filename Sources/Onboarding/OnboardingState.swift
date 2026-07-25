import Foundation

/// Whether the first-run onboarding wizard has been shown before —
/// deliberately a plain `UserDefaults` flag rather than a `LayoutDocument`
/// field, since this has nothing to do with persisted grid/trigger state and
/// doesn't need migration versioning.
public enum OnboardingState {
    private static let key = "com.launchpadnative.app.hasCompletedOnboarding"

    public static func hasCompleted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    public static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }
}
