import CoreFoundation
import Diagnostics
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
        CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Int
    }

    public func setIntegerValue(_ value: Int?, forKey key: String, domain: String) {
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    @discardableResult
    public func synchronize(domain: String) -> Bool {
        CFPreferencesAppSynchronize(domain as CFString)
    }
}

/// Disables/restores macOS's own built-in trackpad pinch gesture that
/// conflicts with this app's own N-finger pinch/spread trigger
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

    /// Only the Pinch key matching this app's own configured finger count
    /// is ever touched — the sibling `*HorizSwipeGesture`/
    /// `*VertSwipeGesture` keys are never referenced anywhere in this type,
    /// structurally: there is no code path here that can construct or
    /// touch a swipe-gesture key name. This app's own trigger is
    /// pinch/spread only, never swipe, so touching swipe assignments would
    /// be an unrelated, unrequested change to the user's system.
    public enum PinchKey: String {
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

    public static func decideTransition(enabled: Bool, desiredFingerCount: Int, existingBackup: GestureConflictBackup?) -> Transition {
        if enabled {
            if let existingBackup, existingBackup.fingerCount == desiredFingerCount {
                return .none
            }
            return .disable(fingerCount: desiredFingerCount, restoringFirst: existingBackup)
        } else {
            guard let existingBackup else { return .none }
            return .restore(existingBackup)
        }
    }

    @discardableResult
    public static func disable(fingerCount: Int, store: TrackpadPreferenceStore = CFPreferencesTrackpadStore()) -> GestureConflictBackup? {
        guard let key = PinchKey(fingerCount: fingerCount) else { return nil }
        var values: [String: Int?] = [:]
        for domain in domains {
            values[domain] = store.integerValue(forKey: key.rawValue, domain: domain)
            store.setIntegerValue(0, forKey: key.rawValue, domain: domain)
            if !store.synchronize(domain: domain) {
                DiagnosticsLog.triggers.error("ConflictingGestureManager: CFPreferencesAppSynchronize failed for \(domain, privacy: .public)")
            }
        }
        return GestureConflictBackup(fingerCount: fingerCount, values: values)
    }

    public static func restore(_ backup: GestureConflictBackup, store: TrackpadPreferenceStore = CFPreferencesTrackpadStore()) {
        guard let key = PinchKey(fingerCount: backup.fingerCount) else { return }
        for domain in domains {
            // Flattens "domain missing from the backup" and "domain present
            // with an explicit nil" identically — both mean "the key didn't
            // exist before," so restore should remove it, not write back 0.
            let original = backup.values[domain] ?? nil
            store.setIntegerValue(original, forKey: key.rawValue, domain: domain)
            store.synchronize(domain: domain)
        }
    }
}
