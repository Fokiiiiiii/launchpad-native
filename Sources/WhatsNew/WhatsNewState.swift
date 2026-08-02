import Foundation

/// Which app version last showed the "What's New" panel — a plain
/// `UserDefaults` flag (mirrors `Onboarding.OnboardingState`'s shape
/// exactly), not a `LayoutDocument` field, since this has nothing to do
/// with persisted grid/trigger state. Stores the version string itself
/// (not a `Bool`) so a version bump after the panel was last shown is
/// enough on its own to trigger it again — no separate "seen this
/// version's notes" bookkeeping needed.
public enum WhatsNewState {
    private static let key = "com.launchpadnative.app.lastShownWhatsNewVersion"

    public static func lastShownVersion(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    public static func markShown(version: String, defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: key)
    }
}
