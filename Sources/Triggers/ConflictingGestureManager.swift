import CoreFoundation
import Diagnostics
import Foundation
import Persistence

/// Thin seam so tests can fake the preference I/O instead of hitting real
/// system prefs — mirrors this project's `RemovalPlanner` (pure) /
/// `RemovalExecutor` (real side effects) split in `Sources/Uninstall`.
public protocol TrackpadPreferenceStore {
    func integerValue(forKey key: String, domain: String) -> Int?
    func setIntegerValue(_ value: Int?, forKey key: String, domain: String)
    @discardableResult func synchronize(domain: String) -> Bool
}

/// Real adapter, backed by `CFPreferences` — a plain plist read/write
/// against ANOTHER app's own preference domain. Deliberately does NOT
/// require Accessibility permission: Accessibility gates driving another
/// app's UI or intercepting global input, not writing a plist file. Uses
/// `kCFPreferencesCurrentUser`/`kCFPreferencesAnyHost` (not
/// `kCFPreferencesCurrentHost`) — confirmed appropriate because a plain
/// `defaults read com.apple.AppleMultitouchTrackpad` (no `-currentHost`
/// flag) already returns the real values on the dev machine used to
/// research this; `-currentHost` would target the ByHost domain instead,
/// which wouldn't match what a later plain `defaults read` reports and
/// could make writes silently appear to do nothing.
public struct CFPreferencesTrackpadStore: TrackpadPreferenceStore {
    public init() {}

    public func integerValue(forKey key: String, domain: String) -> Int? {
        let value = CFPreferencesCopyValue(
            key as CFString,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }

    public func setIntegerValue(_ value: Int?, forKey key: String, domain: String) {
        let property: CFPropertyList?
        if domain == ConflictingGestureManager.launchpadDomain,
           ConflictingGestureManager.dockGestureKeys.contains(key) {
            // Dock stores this preference as a boolean. Keep the generic
            // trackpad adapter integer-based, but preserve the consumer's
            // native plist type for the Launchpad fallback key.
            property = value.map { $0 == 0 ? kCFBooleanFalse : kCFBooleanTrue }
        } else {
            property = value as CFPropertyList?
        }
        CFPreferencesSetValue(key as CFString, property, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    @discardableResult
    public func synchronize(domain: String) -> Bool {
        CFPreferencesSynchronize(
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }
}

/// Disables/restores macOS's own built-in trackpad pinch/navigation and Dock
/// Launchpad/Mission Control/App Exposé gestures that conflict with this app's
/// own N-finger pinch/spread trigger
/// (`MultitouchGestureTrigger`) — see this type's doc comments and the
/// Round 14 plan for the research behind this design. **Deliberately does
/// NOT use Accessibility-gated UI automation** — that path was tested
/// against the real System Settings app and found unreliable (a flaky,
/// lazily-rendered accessibility tree on macOS 26's SwiftUI-based System
/// Settings). A plain `CFPreferences` write to the real, confirmed keys
/// below is used instead, and needs no special permission.
///
/// **Disclosed, unresolved uncertainty** (not fixable from this session —
/// no physical trackpad access to test): whether this write takes effect
/// live or requires the user to log out and back in, and whether `0`
/// really means "off" for these keys — both are working hypotheses from
/// secondary community sources, not independently re-derived by toggling
/// the real System Settings control and diffing.
public enum ConflictingGestureManager {
    /// Both trackpad preference domains — confirmed present, with
    /// identical key sets, on the dev machine used to research this (which
    /// has both a built-in trackpad and a Bluetooth/Magic Trackpad
    /// attached). Write to both so either kind of trackpad is covered.
    public static let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    ]
    /// Dock owns the native Launchpad/Mission Control/App Exposé actions.
    /// Disabling only the trackpad pinch flags leaves those consumers able to
    /// claim the same frame on newer macOS releases, so they participate in
    /// the same reversible transaction.
    public static let launchpadDomain = "com.apple.dock"
    public static let launchpadGestureKey = "showLaunchpadGestureEnabled"
    public static let missionControlGestureKey = "showMissionControlGestureEnabled"
    public static let appExposeGestureKey = "showAppExposeGestureEnabled"
    public static let dockGestureKeys = [
        launchpadGestureKey,
        missionControlGestureKey,
        appExposeGestureKey
    ]

    /// macOS's four-finger navigation preferences. Five-finger variants are
    /// included for forward compatibility but are only written when present;
    /// absent keys remain absent and are never created by this app.
    public static let trackpadSwipeKeys = [
        "TrackpadFourFingerHorizSwipeGesture",
        "TrackpadFourFingerVertSwipeGesture",
        "TrackpadFiveFingerHorizSwipeGesture",
        "TrackpadFiveFingerVertSwipeGesture"
    ]

    /// The two Pinch keys are managed as one transaction. The related
    /// navigation keys are captured separately so legacy restore points remain
    /// safe and absent keys are not created.
    public enum PinchKey: String, CaseIterable {
        case fourFinger = "TrackpadFourFingerPinchGesture"
        case fiveFinger = "TrackpadFiveFingerPinchGesture"

        public init?(fingerCount: Int) {
            switch fingerCount {
            case 4: self = .fourFinger
            case 5: self = .fiveFinger
            default: return nil
            }
        }
    }

    /// Pure decision logic — no I/O. `TriggerCoordinator.apply(_:)` calls
    /// this, then performs whichever side effect it returns.
    public enum Transition: Equatable {
        case none
        case disable(fingerCount: Int, restoringFirst: GestureConflictBackup?)
        case restore(GestureConflictBackup)
    }


    /// Outcome of an attempted preference transaction. A restore point is
    /// exposed only after every domain write has synchronized and read back
    /// as the requested disabled value.
    public enum DisableResult: Equatable, Sendable {
        case succeeded(GestureConflictBackup)
        case failed
    }

    private static let supportedFingerCounts = [4, 5]

    public static func decideTransition(
        enabled: Bool,
        desiredFingerCount: Int,
        existingBackup: GestureConflictBackup?,
        multitouchEnabled: Bool = true
    ) -> Transition {
        if enabled && multitouchEnabled {
            if let existingBackup, existingBackup.fingerCount == desiredFingerCount {
                return .none
            }
            return .disable(fingerCount: desiredFingerCount, restoringFirst: existingBackup)
        }

        guard let existingBackup else { return .none }
        return .restore(existingBackup)
    }

    /// Captures all managed system preferences without writing anything.
    /// Callers use this exact snapshot as the restore point that must be
    /// durable before `disableVerified` is allowed to mutate
    /// CFPreferences. `fingerCount` and `values` retain the old single-key
    /// shape for on-disk and source compatibility.
    public static func captureBackup(
        fingerCount: Int,
        store: TrackpadPreferenceStore = CFPreferencesTrackpadStore()
    ) -> GestureConflictBackup? {
        guard PinchKey(fingerCount: fingerCount) != nil else {
            DiagnosticsLog.triggers.error("ConflictingGestureManager: unsupported finger count \(fingerCount, privacy: .public)")
            return nil
        }

        var valuesByFingerCount: [Int: [String: Int?]] = [:]
        for count in supportedFingerCounts {
            guard let key = PinchKey(fingerCount: count) else { return nil }
            var values: [String: Int?] = [:]
            for domain in domains {
                values[domain] = store.integerValue(forKey: key.rawValue, domain: domain)
            }
            valuesByFingerCount[count] = values
        }
        var trackpadGestureValues: [String: [String: Int?]] = [:]
        for key in trackpadSwipeKeys {
            var values: [String: Int?] = [:]
            for domain in domains {
                values[domain] = store.integerValue(forKey: key, domain: domain)
            }
            trackpadGestureValues[key] = values
        }
        var dockGestureValues: [String: Int?] = [:]
        for key in dockGestureKeys {
            dockGestureValues[key] = store.integerValue(forKey: key, domain: launchpadDomain)
        }
        let launchpadGestureValue = dockGestureValues[launchpadGestureKey] ?? nil
        return GestureConflictBackup(
            fingerCount: fingerCount,
            values: valuesByFingerCount[fingerCount] ?? [:],
            valuesByFingerCount: valuesByFingerCount,
            launchpadGestureValue: launchpadGestureValue,
            launchpadGestureWasPresent: launchpadGestureValue != nil,
            launchpadGestureCaptured: true,
            trackpadGestureValues: trackpadGestureValues,
            dockGestureValues: dockGestureValues,
            dockGesturesCaptured: true
        )
    }

    /// Returns whether a persisted restore point covers every key and domain
    /// this manager mutates. A partial point cannot safely be used for
    /// rollback. Legacy single-key points remain valid until they are
    /// upgraded by `prepareRestorePoint`/`disableVerified`.
    public static func isCompleteRestorePoint(_ backup: GestureConflictBackup) -> Bool {
        restorationEntries(for: backup) != nil
            && isValidLaunchpadMetadata(backup)
            && isValidTrackpadMetadata(backup)
            && isValidDockMetadata(backup)
    }

    /// Attempts to disable the configured pinch key as an all-or-nothing
    /// preference transaction. The coordinator uses selected count
    /// arbitration; the defaults remain broad for legacy callers and
    /// migration tests. The original values are returned only after all
    /// writes synchronize and read back 0; failed writes are rolled back
    /// best-effort and never become a persisted restore point.
    @discardableResult
    public static func disableVerified(
        fingerCount: Int,
        store: TrackpadPreferenceStore = CFPreferencesTrackpadStore(),
        preserving restorePoint: GestureConflictBackup? = nil,
        disableBothFingerCounts: Bool = true,
        disableRelatedNavigation: Bool = true
    ) -> DisableResult {
        guard PinchKey(fingerCount: fingerCount) != nil else {
            DiagnosticsLog.triggers.error("ConflictingGestureManager: unsupported finger count \(fingerCount, privacy: .public)")
            return .failed
        }

        guard let rollback = captureBackup(fingerCount: fingerCount, store: store) else {
            return .failed
        }
        let backup: GestureConflictBackup
        if let restorePoint {
            guard restorePoint.fingerCount == fingerCount,
                  isCompleteRestorePoint(restorePoint) else {
                DiagnosticsLog.triggers.error("ConflictingGestureManager: incomplete or mismatched restore point for \(fingerCount, privacy: .public)")
                return .failed
            }
            backup = mergedRestorePoint(restorePoint, with: rollback, fingerCount: fingerCount)
        } else {
            backup = rollback
        }

        let countsToDisable = disableBothFingerCounts ? supportedFingerCounts : [fingerCount]
        for count in countsToDisable {
            guard let key = PinchKey(fingerCount: count) else { return .failed }
            for domain in domains {
                // Always write the zero, even when the plist already reads
                // zero.  cfprefsd/SystemUIServer can retain the previous
                // consumer state; a same-value write plus synchronize is the
                // only native notification this path owns and makes a
                // re-apply effective without killing a system process.
                store.setIntegerValue(0, forKey: key.rawValue, domain: domain)
                guard store.synchronize(domain: domain) else {
                    DiagnosticsLog.triggers.error("ConflictingGestureManager: synchronize failed while disabling \(key.rawValue, privacy: .public) in \(domain, privacy: .public)")
                    if !restore(rollback, store: store) {
                        DiagnosticsLog.triggers.error("ConflictingGestureManager: rollback failed after synchronize failure for \(key.rawValue, privacy: .public) in \(domain, privacy: .public)")
                    }
                    return .failed
                }
                guard store.integerValue(forKey: key.rawValue, domain: domain) == 0 else {
                    DiagnosticsLog.triggers.error("ConflictingGestureManager: readback failed while disabling \(key.rawValue, privacy: .public) in \(domain, privacy: .public)")
                    if !restore(rollback, store: store) {
                        DiagnosticsLog.triggers.error("ConflictingGestureManager: rollback failed after readback failure for \(key.rawValue, privacy: .public) in \(domain, privacy: .public)")
                    }
                    return .failed
                }
            }
        }

        guard disableRelatedNavigation else {
            return .succeeded(backup)
        }

        for key in trackpadSwipeKeys {
            for domain in domains {
                // Do not create a navigation key that was absent on this Mac.
                guard let values = rollback.trackpadGestureValues?[key],
                      case .some(.some) = values[domain] else { continue }
                store.setIntegerValue(0, forKey: key, domain: domain)
                guard store.synchronize(domain: domain),
                      store.integerValue(forKey: key, domain: domain) == 0 else {
                    DiagnosticsLog.triggers.error("ConflictingGestureManager: could not disable \(key, privacy: .public) in \(domain, privacy: .public)")
                    if !restore(rollback, store: store) {
                        DiagnosticsLog.triggers.error("ConflictingGestureManager: rollback failed after \(key, privacy: .public) failure")
                    }
                    return .failed
                }
            }
        }

        for key in dockGestureKeys {
            // Dock values are booleans in the native plist. As with the
            // trackpad keys, leave an absent preference absent.
            guard let dockValues = rollback.dockGestureValues,
                  case .some(.some) = dockValues[key] else { continue }
            store.setIntegerValue(0, forKey: key, domain: launchpadDomain)
            guard store.synchronize(domain: launchpadDomain),
                  store.integerValue(forKey: key, domain: launchpadDomain) == 0 else {
                DiagnosticsLog.triggers.error("ConflictingGestureManager: could not disable native Dock gesture \(key, privacy: .public)")
                if !restore(rollback, store: store) {
                    DiagnosticsLog.triggers.error("ConflictingGestureManager: rollback failed after native Dock gesture failure")
                }
                return .failed
            }
        }

        return .succeeded(backup)
    }

    @discardableResult
    public static func disable(fingerCount: Int, store: TrackpadPreferenceStore = CFPreferencesTrackpadStore()) -> GestureConflictBackup? {
        switch disableVerified(fingerCount: fingerCount, store: store) {
        case .succeeded(let backup): return backup
        case .failed: return nil
        }
    }

    @discardableResult
    public static func restore(
        _ backup: GestureConflictBackup,
        store: TrackpadPreferenceStore = CFPreferencesTrackpadStore()
    ) -> Bool {
        guard let entries = restorationEntries(for: backup),
              isValidLaunchpadMetadata(backup),
              isValidTrackpadMetadata(backup),
              isValidDockMetadata(backup) else {
            DiagnosticsLog.triggers.error("ConflictingGestureManager: incomplete restore point for \(backup.fingerCount, privacy: .public)")
            return false
        }

        var success = true
        for (count, values) in entries {
            guard let key = PinchKey(fingerCount: count) else { return false }
            for domain in domains {
                // Flattens “domain missing from the backup” and “domain
                // present with an explicit nil” identically — both mean “the
                // key did not exist before,” so restore should remove it.
                let original = values[domain] ?? nil
                store.setIntegerValue(original, forKey: key.rawValue, domain: domain)
                guard store.synchronize(domain: domain) else {
                    DiagnosticsLog.triggers.error("ConflictingGestureManager: synchronize failed while restoring \(key.rawValue, privacy: .public) in \(domain, privacy: .public)")
                    success = false
                    continue
                }
                let restored = store.integerValue(forKey: key.rawValue, domain: domain)
                guard restored == original else {
                    DiagnosticsLog.triggers.error("ConflictingGestureManager: readback failed while restoring \(key.rawValue, privacy: .public) in \(domain, privacy: .public)")
                    success = false
                    continue
                }
            }
        }
        if let trackpadGestureValues = backup.trackpadGestureValues {
            for key in trackpadSwipeKeys {
                guard let values = trackpadGestureValues[key] else { continue }
                for domain in domains {
                    let original = values[domain] ?? nil
                    store.setIntegerValue(original, forKey: key, domain: domain)
                    guard store.synchronize(domain: domain) else {
                        DiagnosticsLog.triggers.error("ConflictingGestureManager: synchronize failed while restoring \(key, privacy: .public) in \(domain, privacy: .public)")
                        success = false
                        continue
                    }
                    if store.integerValue(forKey: key, domain: domain) != original {
                        DiagnosticsLog.triggers.error("ConflictingGestureManager: readback failed while restoring \(key, privacy: .public) in \(domain, privacy: .public)")
                        success = false
                    }
                }
            }
        }

        if backup.dockGesturesCaptured, let dockGestureValues = backup.dockGestureValues {
            for key in dockGestureKeys {
                let original = dockGestureValues[key] ?? nil
                store.setIntegerValue(original, forKey: key, domain: launchpadDomain)
                guard store.synchronize(domain: launchpadDomain) else {
                    DiagnosticsLog.triggers.error("ConflictingGestureManager: synchronize failed while restoring native Dock gesture \(key, privacy: .public)")
                    success = false
                    continue
                }
                if store.integerValue(forKey: key, domain: launchpadDomain) != original {
                    DiagnosticsLog.triggers.error("ConflictingGestureManager: readback failed while restoring native Dock gesture \(key, privacy: .public)")
                    success = false
                }
            }
        } else if backup.launchpadGestureCaptured {
            // Backups from the first Dock integration only owned Launchpad.
            // Do not touch the newer Mission Control/App Exposé keys.
            let originalLaunchpadValue = backup.launchpadGestureValue
            store.setIntegerValue(originalLaunchpadValue, forKey: launchpadGestureKey, domain: launchpadDomain)
            guard store.synchronize(domain: launchpadDomain) else {
                DiagnosticsLog.triggers.error("ConflictingGestureManager: synchronize failed while restoring native Launchpad gesture")
                return false
            }
            if store.integerValue(forKey: launchpadGestureKey, domain: launchpadDomain) != originalLaunchpadValue {
                DiagnosticsLog.triggers.error("ConflictingGestureManager: readback failed while restoring native Launchpad gesture")
                success = false
            }
        }
        return success
    }

    private static func restorationEntries(
        for backup: GestureConflictBackup
    ) -> [(Int, [String: Int?])]? {
        if let valuesByFingerCount = backup.valuesByFingerCount {
            guard Set(valuesByFingerCount.keys) == Set(supportedFingerCounts) else {
                return nil
            }
            for count in supportedFingerCounts {
                guard let values = valuesByFingerCount[count],
                      Set(values.keys) == Set(domains) else {
                    return nil
                }
            }
            return supportedFingerCounts.compactMap { count in
                guard let values = valuesByFingerCount[count] else { return nil }
                return (count, values)
            }
        }

        guard PinchKey(fingerCount: backup.fingerCount) != nil,
              Set(backup.values.keys) == Set(domains) else {
            return nil
        }
        return [(backup.fingerCount, backup.values)]
    }

    private static func isValidLaunchpadMetadata(_ backup: GestureConflictBackup) -> Bool {
        !backup.launchpadGestureCaptured
            || !backup.launchpadGestureWasPresent
            || backup.launchpadGestureValue != nil
    }

    private static func isValidTrackpadMetadata(_ backup: GestureConflictBackup) -> Bool {
        guard let values = backup.trackpadGestureValues else { return true }
        guard Set(values.keys) == Set(trackpadSwipeKeys) else { return false }
        return trackpadSwipeKeys.allSatisfy { key in
            guard let domainsForKey = values[key] else { return false }
            return Set(domainsForKey.keys) == Set(domains)
        }
    }

    private static func isValidDockMetadata(_ backup: GestureConflictBackup) -> Bool {
        guard backup.dockGesturesCaptured else { return backup.dockGestureValues == nil }
        guard let values = backup.dockGestureValues else { return false }
        return Set(values.keys) == Set(dockGestureKeys)
    }

    private static func mergedRestorePoint(
        _ restorePoint: GestureConflictBackup,
        with current: GestureConflictBackup,
        fingerCount: Int
    ) -> GestureConflictBackup {
        var valuesByFingerCount = restorePoint.valuesByFingerCount ?? current.valuesByFingerCount ?? [:]
        if restorePoint.valuesByFingerCount == nil {
            valuesByFingerCount[fingerCount] = restorePoint.values
        }
        let launchpadCaptured = restorePoint.launchpadGestureCaptured || current.launchpadGestureCaptured
        let launchpadValue = restorePoint.launchpadGestureCaptured
            ? restorePoint.launchpadGestureValue
            : current.launchpadGestureValue
        let launchpadWasPresent = restorePoint.launchpadGestureCaptured
            ? restorePoint.launchpadGestureWasPresent
            : current.launchpadGestureWasPresent
        let trackpadGestureValues = restorePoint.trackpadGestureValues ?? current.trackpadGestureValues
        let dockGesturesCaptured = restorePoint.dockGesturesCaptured || current.dockGesturesCaptured
        let dockGestureValues = restorePoint.dockGesturesCaptured
            ? restorePoint.dockGestureValues
            : current.dockGestureValues
        return GestureConflictBackup(
            fingerCount: fingerCount,
            values: restorePoint.values,
            valuesByFingerCount: valuesByFingerCount,
            launchpadGestureValue: launchpadValue,
            launchpadGestureWasPresent: launchpadWasPresent,
            launchpadGestureCaptured: launchpadCaptured,
            trackpadGestureValues: trackpadGestureValues,
            dockGestureValues: dockGestureValues,
            dockGesturesCaptured: dockGesturesCaptured
        )
    }

}
