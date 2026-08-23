import Foundation
import Persistence

/// The decisions `AppDelegate` makes about trigger settings, separated from the
/// act of applying them.
///
/// These were private methods on the delegate, which meant the rules could only
/// be exercised by launching the app — and the one about keeping a restore
/// point (`durableSettings`) is precisely the kind of rule that is invisible
/// until the day it matters, because getting it wrong only shows up as a lost
/// backup after a failure.
public enum TriggerSettingsPolicy {
    /// Brings a requested configuration in line with what can actually hold.
    ///
    /// - Parameter forceAllTriggers: the debug override, passed in rather than
    ///   read from the environment here, so the rule is testable without
    ///   setting process-wide state.
    public static func normalized(
        _ requested: TriggerSettings,
        forceAllTriggers: Bool = false
    ) -> TriggerSettings {
        var settings = requested
        if forceAllTriggers {
            settings.f4Enabled = true
            settings.hotCornersEnabled["bottomRight"] = true
            settings.multitouchGestureEnabled = true
        }
        // The raw MultitouchSupport listener is passive, so a multitouch
        // trigger owns the matching macOS conflict policy as one transaction: a
        // stale persisted opt-out lets the system consume the same physical
        // gesture first.
        settings.gestureConflictPreventionEnabled = settings.multitouchGestureEnabled
        return settings
    }

    /// Whether a change is "same gesture, different finger count" — the case
    /// where a restore point taken for the old count no longer describes what
    /// is about to be changed.
    public static func isGestureConflictFingerSwitch(
        from previous: TriggerSettings,
        to candidate: TriggerSettings
    ) -> Bool {
        guard previous.multitouchGestureEnabled,
              candidate.multitouchGestureEnabled,
              let previousBackup = previous.gestureConflictBackup else {
            return false
        }
        return previousBackup.fingerCount != candidate.multitouchFingerCount
    }

    /// What to persist when rolling back to `previous` after a failure.
    ///
    /// The whole point is the failed case: never erase the only restore point
    /// while the system preferences are in an indeterminate state. Keeping it
    /// on disk lets the next attempt retry the exact values, instead of
    /// treating whatever is there now as the user's original preference.
    public static func durableRollbackSettings(
        previous: TriggerSettings,
        rollbackFailed: Bool,
        candidateBackup: GestureConflictBackup?,
        currentBackup: GestureConflictBackup?
    ) -> TriggerSettings {
        var durable = previous
        if rollbackFailed {
            durable.gestureConflictBackup =
                candidateBackup ?? currentBackup ?? previous.gestureConflictBackup
        }
        return durable
    }
}
