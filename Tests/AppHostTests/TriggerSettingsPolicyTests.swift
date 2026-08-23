import Foundation
import Persistence
import Testing
@testable import AppHost

private func settings(
    multitouch: Bool = false,
    fingerCount: Int = 4,
    conflictPrevention: Bool = false,
    backup: GestureConflictBackup? = nil
) -> TriggerSettings {
    var s = TriggerSettings.default
    s.multitouchGestureEnabled = multitouch
    s.multitouchFingerCount = fingerCount
    s.gestureConflictPreventionEnabled = conflictPrevention
    s.gestureConflictBackup = backup
    return s
}

private func backup(fingerCount: Int) -> GestureConflictBackup {
    GestureConflictBackup(fingerCount: fingerCount, values: [:])
}

// MARK: normalization

/// The conflict policy is not an independent preference: the raw multitouch
/// listener is passive, so whenever the gesture is on, macOS's own handling of
/// the same physical gesture has to be turned off with it. A stale persisted
/// opt-out means the system eats the gesture first.
@Test func conflictPreventionAlwaysFollowsTheMultitouchTrigger() {
    let on = TriggerSettingsPolicy.normalized(settings(multitouch: true, conflictPrevention: false))
    #expect(on.gestureConflictPreventionEnabled)

    let off = TriggerSettingsPolicy.normalized(settings(multitouch: false, conflictPrevention: true))
    #expect(off.gestureConflictPreventionEnabled == false)
}

@Test func normalizationLeavesEverythingElseAlone() {
    var requested = settings(multitouch: true, fingerCount: 5)
    requested.f4Enabled = false
    requested.hotkeyEnabled = true
    let normalized = TriggerSettingsPolicy.normalized(requested)
    #expect(normalized.f4Enabled == false)
    #expect(normalized.hotkeyEnabled)
    #expect(normalized.multitouchFingerCount == 5)
}

/// The debug override exists to verify triggers without going through Settings.
/// It must not be reachable unless explicitly asked for.
@Test func theDebugOverrideOnlyAppliesWhenRequested() {
    let plain = TriggerSettingsPolicy.normalized(settings(multitouch: false), forceAllTriggers: false)
    #expect(plain.multitouchGestureEnabled == false)
    #expect(plain.f4Enabled == TriggerSettings.default.f4Enabled)

    let forced = TriggerSettingsPolicy.normalized(settings(multitouch: false), forceAllTriggers: true)
    #expect(forced.f4Enabled)
    #expect(forced.multitouchGestureEnabled)
    #expect(forced.hotCornersEnabled["bottomRight"] == true)
    // And the rule above still holds on top of the override.
    #expect(forced.gestureConflictPreventionEnabled)
}

// MARK: finger-count switch

/// Changing finger count while the gesture stays on means the restore point
/// taken for the old count no longer describes what is about to change.
@Test func switchingFingerCountWithTheGestureOnIsDetected() {
    let previous = settings(multitouch: true, fingerCount: 4, backup: backup(fingerCount: 4))
    let candidate = settings(multitouch: true, fingerCount: 5)
    #expect(TriggerSettingsPolicy.isGestureConflictFingerSwitch(from: previous, to: candidate))
}

@Test func thesameFingerCountIsNotASwitch() {
    let previous = settings(multitouch: true, fingerCount: 4, backup: backup(fingerCount: 4))
    let candidate = settings(multitouch: true, fingerCount: 4)
    #expect(TriggerSettingsPolicy.isGestureConflictFingerSwitch(from: previous, to: candidate) == false)
}

/// Turning the gesture on or off is a different transition, handled elsewhere —
/// treating it as a finger switch would restore the wrong thing.
@Test func togglingTheGestureIsNotAFingerSwitch() {
    let wasOff = settings(multitouch: false, fingerCount: 4, backup: backup(fingerCount: 4))
    #expect(TriggerSettingsPolicy.isGestureConflictFingerSwitch(from: wasOff, to: settings(multitouch: true, fingerCount: 5)) == false)

    let turningOff = settings(multitouch: true, fingerCount: 4, backup: backup(fingerCount: 4))
    #expect(TriggerSettingsPolicy.isGestureConflictFingerSwitch(from: turningOff, to: settings(multitouch: false, fingerCount: 5)) == false)
}

/// With no restore point there is nothing that could be stale.
@Test func withoutABackupThereIsNothingToSwitch() {
    let previous = settings(multitouch: true, fingerCount: 4, backup: nil)
    #expect(TriggerSettingsPolicy.isGestureConflictFingerSwitch(from: previous, to: settings(multitouch: true, fingerCount: 5)) == false)
}

// MARK: rollback

/// A successful rollback persists exactly what it rolled back to.
@Test func aSuccessfulRollbackPersistsThePreviousSettingsUnchanged() {
    let previous = settings(multitouch: true, fingerCount: 4, backup: backup(fingerCount: 4))
    let durable = TriggerSettingsPolicy.durableRollbackSettings(
        previous: previous,
        rollbackFailed: false,
        candidateBackup: backup(fingerCount: 5),
        currentBackup: backup(fingerCount: 9)
    )
    #expect(durable.gestureConflictBackup?.fingerCount == 4)
}

/// The case that matters: the rollback itself failed, so the system preferences
/// are in an indeterminate state. Erasing the restore point here would leave
/// nothing to retry from, and whatever is currently on the system would be
/// mistaken for the user's original choice.
@Test func aFailedRollbackKeepsARestorePoint() {
    let previous = settings(multitouch: true, fingerCount: 4, backup: nil)
    let durable = TriggerSettingsPolicy.durableRollbackSettings(
        previous: previous,
        rollbackFailed: true,
        candidateBackup: backup(fingerCount: 5),
        currentBackup: nil
    )
    #expect(durable.gestureConflictBackup?.fingerCount == 5, "the in-flight backup is the freshest restore point")
}

@Test func aFailedRollbackFallsBackThroughEveryAvailableBackup() {
    let previous = settings(multitouch: true, fingerCount: 4, backup: backup(fingerCount: 4))

    // No candidate: use whatever the model currently holds.
    let fromCurrent = TriggerSettingsPolicy.durableRollbackSettings(
        previous: previous, rollbackFailed: true, candidateBackup: nil, currentBackup: backup(fingerCount: 9)
    )
    #expect(fromCurrent.gestureConflictBackup?.fingerCount == 9)

    // Neither: fall back to the one being rolled back to, rather than nothing.
    let fromPrevious = TriggerSettingsPolicy.durableRollbackSettings(
        previous: previous, rollbackFailed: true, candidateBackup: nil, currentBackup: nil
    )
    #expect(fromPrevious.gestureConflictBackup?.fingerCount == 4)
}
