import Diagnostics
import Persistence

public struct TriggerActivationReport: Sendable {
    public var hotkeyRegistered: Bool
    public var f4Active: Bool
    public var multitouchActive: Bool
    public var multitouchEventArbitrationActive: Bool
    public var gestureConflictUpdate: GestureConflictUpdate = .unchanged

    /// What `apply(_:)` did (if anything) to `TriggerSettings.gestureConflictBackup`
    /// — the caller must persist this back to disk (see `AppDelegate`'s
    /// doc comment on why it re-reads a fresh settings copy for this
    /// rather than reusing a possibly debug-mutated one).
    public enum GestureConflictUpdate: Sendable, Equatable {
        case unchanged
        case cleared
        case updated(GestureConflictBackup)
        case failed
    }
}

/// Applies `TriggerSettings` to the four trigger mechanisms and forwards
/// every activation to one callback. Each trigger fails independently
/// (missing permission, no hardware, combo already claimed) without taking
/// the others down — capability-level isolation, same rule as
/// `PrivateAPIResolver`.
@MainActor
public final class TriggerCoordinator {
    private let hotkey: GlobalHotkeyTrigger
    private let hotCorner: HotCornerTrigger
    private let f4: F4Trigger
    private let multitouch: MultitouchGestureTrigger
    private let trackpadPreferenceStore: TrackpadPreferenceStore
    private var activeGestureConflictBackup: GestureConflictBackup?
    /// Optional candidate ordering supplied by a caller that coalesces rapid
    /// Settings edits. Legacy callers omit it and retain the existing apply
    /// behavior; a lower token is ignored before any trigger or preference
    /// side effect occurs.
    private var latestCandidateToken: UInt = 0
    private var lastActivationReport = TriggerActivationReport(
        hotkeyRegistered: false,
        f4Active: false,
        multitouchActive: false,
        multitouchEventArbitrationActive: false
    )

    /// `onActivate` (toggle semantics) drives the hotkey/hot-corner/F4
    /// triggers. The multitouch gesture uses real Launchpad semantics
    /// instead — pinch closed opens, spread apart closes — so it takes
    /// separate `onPinchClose`/`onSpreadOpen` callbacks rather than a toggle.
    public init(
        onActivate: @escaping () -> Void,
        onPinchClose: @escaping () -> Void,
        onSpreadOpen: @escaping () -> Void,
        trackpadPreferenceStore: TrackpadPreferenceStore = CFPreferencesTrackpadStore()
    ) {
        hotkey = GlobalHotkeyTrigger(onTrigger: onActivate)
        hotCorner = HotCornerTrigger(onActivate: onActivate)
        f4 = F4Trigger(onActivate: onActivate)
        multitouch = MultitouchGestureTrigger(onPinchClose: onPinchClose, onSpreadOpen: onSpreadOpen)
        self.trackpadPreferenceStore = trackpadPreferenceStore
    }

    /// Produces the settings copy that is safe to persist before `apply(_:)`
    /// mutates CFPreferences.  A new target finger count gets a read-only
    /// snapshot first; an existing complete snapshot remains authoritative so
    /// a re-apply cannot accidentally capture the already-disabled value.
    /// Returns `nil` when the requested transition cannot have a complete
    /// restore point (for example, an unsupported finger count or a partial
    /// point that would need restoring).
    public func prepareRestorePoint(for settings: TriggerSettings) -> TriggerSettings? {
        let existingBackup = activeGestureConflictBackup ?? settings.gestureConflictBackup

        if settings.multitouchGestureEnabled {
            if let existingBackup,
               existingBackup.fingerCount == settings.multitouchFingerCount,
               ConflictingGestureManager.isCompleteRestorePoint(existingBackup) {
                var prepared = settings
                let needsUpgrade = existingBackup.valuesByFingerCount == nil
                    || !existingBackup.launchpadGestureCaptured
                    || existingBackup.trackpadGestureValues == nil
                    || !existingBackup.dockGesturesCaptured
                prepared.gestureConflictBackup = needsUpgrade
                    ? upgradedRestorePoint(existingBackup, fingerCount: settings.multitouchFingerCount)
                    : existingBackup
                return prepared
            }

            guard let captured = ConflictingGestureManager.captureBackup(
                fingerCount: settings.multitouchFingerCount,
                store: trackpadPreferenceStore
            ) else {
                return nil
            }
            var prepared = settings
            prepared.gestureConflictBackup = captured
            return prepared
        }

        if let existingBackup {
            guard ConflictingGestureManager.isCompleteRestorePoint(existingBackup) else {
                return nil
            }
            if existingBackup.valuesByFingerCount == nil || !existingBackup.launchpadGestureCaptured {
                var prepared = settings
                prepared.gestureConflictBackup = upgradedRestorePoint(
                    existingBackup,
                    fingerCount: existingBackup.fingerCount
                )
                return prepared
            }
        }
        return settings
    }

    /// Restores the currently active conflict preference before a finger-count
    /// transition begins. The fallback is used on startup when the coordinator
    /// has not yet loaded an in-memory active backup. A failed restore keeps
    /// the backup attached so the caller can retry or roll back safely.
    @discardableResult
    public func restoreGestureConflictForTransition(
        fallback: GestureConflictBackup?
    ) -> Bool {
        guard let backup = activeGestureConflictBackup ?? fallback else {
            return true
        }
        activeGestureConflictBackup = backup
        guard ConflictingGestureManager.restore(backup, store: trackpadPreferenceStore) else {
            DiagnosticsLog.triggers.error("ConflictingGestureManager: could not restore the old pinch preference before a finger-count transition")
            return false
        }
        activeGestureConflictBackup = nil
        return true
    }

    /// Reasserts the selected finger preference without restarting the raw
    /// listener. macOS can reload its gesture consumer independently of this
    /// process; the next launcher open is a cheap, deterministic point to
    /// resend the already durable zero value.
    @discardableResult
    public func reinforceGestureConflict() -> Bool {
        guard let backup = activeGestureConflictBackup,
              ConflictingGestureManager.PinchKey(fingerCount: backup.fingerCount) != nil
        else { return false }
        switch ConflictingGestureManager.disableVerified(
            fingerCount: backup.fingerCount,
            store: trackpadPreferenceStore,
            preserving: backup,
            disableBothFingerCounts: false,
            disableRelatedNavigation: false
        ) {
        case .succeeded(let refreshed):
            activeGestureConflictBackup = refreshed
            return true
        case .failed:
            DiagnosticsLog.triggers.error("ConflictingGestureManager: could not reassert the saved pinch preferences")
            return false
        }
    }

    @discardableResult
    public func apply(
        _ settings: TriggerSettings,
        candidateToken: UInt? = nil
    ) -> TriggerActivationReport {
        if let candidateToken {
            guard candidateToken >= latestCandidateToken else {
                return lastActivationReport
            }
            latestCandidateToken = candidateToken
        }
        hotkey.unregister()
        var hotkeyRegistered = false
        if settings.hotkeyEnabled, let keyCode = settings.hotkeyKeyCode {
            hotkeyRegistered = hotkey.register(keyCode: UInt32(keyCode), modifiers: UInt32(settings.hotkeyModifierFlags))
            if !hotkeyRegistered {
                DiagnosticsLog.triggers.error("Hotkey registration failed — likely claimed by another app or the system")
            }
        }

        let hotCornerConfigs = Self.hotCornerConfigs(from: settings)
        hotCorner.configure(hotCornerConfigs)
        // Only hold the global mouseMoved monitor when a corner can actually
        // fire. `hotCornerConfigs(from:)` always returns an entry per corner
        // (disabled ones included), so starting unconditionally installed a
        // monitor that hops to the main actor for *every* pointer movement —
        // dozens to hundreds of tasks a second — even for users who have every
        // corner switched off. `apply` runs on each settings change, so
        // enabling a corner starts the monitor right back up.
        if hotCornerConfigs.values.contains(where: \.enabled) {
            hotCorner.start()
        } else {
            hotCorner.stop()
        }

        f4.stop()
        var f4Active = false
        if settings.f4Enabled {
            f4Active = f4.start()
        }

        multitouch.stop()
        multitouch.updateRequiredContactCount(settings.multitouchFingerCount)
        multitouch.updateSensitivity(Float(settings.multitouchSensitivity))

        // The raw listener cannot intercept the system's gesture consumer.
        // Keep conflict suppression inseparable from the listener so a stale
        // legacy Boolean can never leave the standard gesture owning input.
        let conflictPreventionEnabled = settings.multitouchGestureEnabled

        if activeGestureConflictBackup == nil {
            activeGestureConflictBackup = settings.gestureConflictBackup
        }
        let existingBackup = activeGestureConflictBackup ?? settings.gestureConflictBackup
        var gestureConflictUpdate: TriggerActivationReport.GestureConflictUpdate = .unchanged
        var conflictReady = true
        let transition = ConflictingGestureManager.decideTransition(
            enabled: conflictPreventionEnabled,
            desiredFingerCount: settings.multitouchFingerCount,
            existingBackup: existingBackup,
            multitouchEnabled: settings.multitouchGestureEnabled
        )
        switch transition {
        case .none:
            if conflictPreventionEnabled,
               let existingBackup,
               existingBackup.fingerCount == settings.multitouchFingerCount {
                switch ConflictingGestureManager.disableVerified(
                    fingerCount: settings.multitouchFingerCount,
                    store: trackpadPreferenceStore,
                    preserving: existingBackup,
                    disableBothFingerCounts: false,
                    disableRelatedNavigation: false
                ) {
                case .succeeded(let backup):
                    // A persisted restore point remains the source of truth;
                    // the readback above only re-enforces its disabled value.
                    activeGestureConflictBackup = backup
                    if backup != existingBackup {
                        // A legacy restore point may be upgraded with the
                        // navigation/Dock keys on this first re-apply. Make
                        // that durable instead of silently discarding the
                        // newly captured restore values.
                        gestureConflictUpdate = .updated(backup)
                    }
                case .failed:
                    DiagnosticsLog.triggers.error("ConflictingGestureManager: could not re-enforce the saved pinch preference")
                    conflictReady = false
                    gestureConflictUpdate = .failed
                    activeGestureConflictBackup = existingBackup
                }
            } else {
                activeGestureConflictBackup = existingBackup
            }
        case .disable(let fingerCount, let restoringFirst):
            if let restoringFirst {
                guard ConflictingGestureManager.restore(restoringFirst, store: trackpadPreferenceStore) else {
                    DiagnosticsLog.triggers.error("ConflictingGestureManager: could not restore the previous pinch preference before switching finger count")
                    conflictReady = false
                    gestureConflictUpdate = .failed
                    activeGestureConflictBackup = restoringFirst
                    break
                }
                activeGestureConflictBackup = nil
            }
            switch ConflictingGestureManager.disableVerified(
                fingerCount: fingerCount,
                store: trackpadPreferenceStore,
                disableBothFingerCounts: false,
                disableRelatedNavigation: false
            ) {
            case .succeeded(let newBackup):
                activeGestureConflictBackup = newBackup
                gestureConflictUpdate = .updated(newBackup)
            case .failed:
                DiagnosticsLog.triggers.error("ConflictingGestureManager: could not disable the configured pinch preference")
                conflictReady = false
                activeGestureConflictBackup = nil
                gestureConflictUpdate = .failed
            }
        case .restore(let backup):
            if ConflictingGestureManager.restore(backup, store: trackpadPreferenceStore) {
                activeGestureConflictBackup = nil
                gestureConflictUpdate = .cleared
            } else {
                DiagnosticsLog.triggers.error("ConflictingGestureManager: could not restore the saved pinch preference")
                conflictReady = false
                gestureConflictUpdate = .failed
                activeGestureConflictBackup = backup
            }
        }

        var multitouchActive = false
        var multitouchEventArbitrationActive = false
        if settings.multitouchGestureEnabled, conflictReady {
            let multitouchReport = multitouch.start()
            multitouchActive = multitouchReport.rawListenerActive
            multitouchEventArbitrationActive = multitouchReport.eventArbitrationActive
            if !multitouchActive {
                DiagnosticsLog.triggers.error("Multitouch gesture listener failed to start")
                if let backup = activeGestureConflictBackup {
                    if ConflictingGestureManager.restore(backup, store: trackpadPreferenceStore) {
                        activeGestureConflictBackup = nil
                    } else {
                        DiagnosticsLog.triggers.error("ConflictingGestureManager: could not restore the saved pinch preference after listener start failure")
                    }
                }
                // A listener that did not start must never be reported as an
                // applied or unchanged activation, even when conflict
                // prevention was disabled and there was no backup to restore.
                gestureConflictUpdate = .failed
            }
        }

        let report = TriggerActivationReport(
            hotkeyRegistered: hotkeyRegistered,
            f4Active: f4Active,
            multitouchActive: multitouchActive,
            multitouchEventArbitrationActive: multitouchEventArbitrationActive,
            gestureConflictUpdate: gestureConflictUpdate
        )
        lastActivationReport = report
        return report
    }

    public func stopAll() {
        hotkey.unregister()
        hotCorner.stop()
        f4.stop()
        multitouch.stop()
        if let backup = activeGestureConflictBackup {
            if ConflictingGestureManager.restore(backup, store: trackpadPreferenceStore) {
                activeGestureConflictBackup = nil
            } else {
                DiagnosticsLog.triggers.error("ConflictingGestureManager: could not restore the saved pinch preference while stopping triggers")
            }
        }
    }

    private static func hotCornerConfigs(from settings: TriggerSettings) -> [ScreenCorner: HotCornerConfig] {
        var configs: [ScreenCorner: HotCornerConfig] = [:]
        for corner in ScreenCorner.allCases {
            let enabled = settings.hotCornersEnabled[corner.rawValue] ?? false
            configs[corner] = HotCornerConfig(enabled: enabled)
        }
        return configs
    }

    /// Upgrades a legacy single-key restore point by read-only capturing the
    /// sibling pinch key before the next external write. The legacy selected
    /// key remains authoritative so an external re-enable cannot overwrite
    /// the user's original restore value.
    private func upgradedRestorePoint(
        _ backup: GestureConflictBackup,
        fingerCount: Int
    ) -> GestureConflictBackup {
        guard backup.valuesByFingerCount == nil
                || !backup.launchpadGestureCaptured
                || backup.trackpadGestureValues == nil
                || !backup.dockGesturesCaptured,
              let captured = ConflictingGestureManager.captureBackup(
                  fingerCount: fingerCount,
                  store: trackpadPreferenceStore
              ),
              var valuesByFingerCount = captured.valuesByFingerCount else {
            return backup
        }
        if backup.valuesByFingerCount == nil {
            valuesByFingerCount[fingerCount] = backup.values
        } else if let existing = backup.valuesByFingerCount {
            valuesByFingerCount = existing
        }
        let launchpadValue = backup.launchpadGestureCaptured
            ? backup.launchpadGestureValue
            : captured.launchpadGestureValue
        let launchpadWasPresent = backup.launchpadGestureCaptured
            ? backup.launchpadGestureWasPresent
            : captured.launchpadGestureWasPresent
        let trackpadGestureValues = backup.trackpadGestureValues ?? captured.trackpadGestureValues
        let dockGesturesCaptured = backup.dockGesturesCaptured || captured.dockGesturesCaptured
        let dockGestureValues = backup.dockGesturesCaptured
            ? backup.dockGestureValues
            : captured.dockGestureValues
        return GestureConflictBackup(
            fingerCount: fingerCount,
            values: backup.values,
            valuesByFingerCount: valuesByFingerCount,
            launchpadGestureValue: launchpadValue,
            launchpadGestureWasPresent: launchpadWasPresent,
            launchpadGestureCaptured: true,
            trackpadGestureValues: trackpadGestureValues,
            dockGestureValues: dockGestureValues,
            dockGesturesCaptured: dockGesturesCaptured
        )
    }
}
