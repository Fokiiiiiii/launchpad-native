import Persistence
import Testing
@testable import Triggers

private final class FakeTrackpadPreferenceStore: TrackpadPreferenceStore {
    private(set) var values: [String: [String: Int]] = [:]
    private(set) var touchedKeys: Set<String> = []
    private(set) var synchronizeCallCount = 0

    init(initialValues: [String: [String: Int]] = [:]) {
        values = initialValues
    }

    func integerValue(forKey key: String, domain: String) -> Int? {
        values[domain]?[key]
    }

    func setIntegerValue(_ value: Int?, forKey key: String, domain: String) {
        touchedKeys.insert(key)
        if let value {
            values[domain, default: [:]][key] = value
        } else {
            values[domain]?.removeValue(forKey: key)
        }
    }

    @discardableResult
    func synchronize(domain: String) -> Bool {
        synchronizeCallCount += 1
        return true
    }
}

private let fourFingerKey = "TrackpadFourFingerPinchGesture"
private let fiveFingerKey = "TrackpadFiveFingerPinchGesture"

@Test func decideTransitionNoneWhenDisabledAndNoExistingBackup() {
    let transition = ConflictingGestureManager.decideTransition(enabled: false, desiredFingerCount: 4, existingBackup: nil)
    #expect(transition == .none)
}

@Test func decideTransitionDisablesFreshWhenTurnedOnWithNoPriorBackup() {
    let transition = ConflictingGestureManager.decideTransition(enabled: true, desiredFingerCount: 4, existingBackup: nil)
    #expect(transition == .disable(fingerCount: 4, restoringFirst: nil))
}

@Test func decideTransitionNoneWhenAlreadyEnabledForSameFingerCount() {
    let backup = GestureConflictBackup(fingerCount: 4, values: [:])
    let transition = ConflictingGestureManager.decideTransition(enabled: true, desiredFingerCount: 4, existingBackup: backup)
    #expect(transition == .none)
}

@Test func decideTransitionRestoresOldAndDisablesNewWhenFingerCountChangedWhileEnabled() {
    let backup = GestureConflictBackup(fingerCount: 4, values: [:])
    let transition = ConflictingGestureManager.decideTransition(enabled: true, desiredFingerCount: 5, existingBackup: backup)
    #expect(transition == .disable(fingerCount: 5, restoringFirst: backup))
}

@Test func decideTransitionRestoresAndClearsWhenTurnedOff() {
    let backup = GestureConflictBackup(fingerCount: 4, values: [:])
    let transition = ConflictingGestureManager.decideTransition(enabled: false, desiredFingerCount: 4, existingBackup: backup)
    #expect(transition == .restore(backup))
}

@Test func disableBacksUpExistingValueAcrossBothDomainsAndWritesZero() {
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 2]
    ])
    let backup = ConflictingGestureManager.disable(fingerCount: 4, store: store)

    #expect(backup?.fingerCount == 4)
    #expect(backup?.values["com.apple.AppleMultitouchTrackpad"] == 2)
    #expect(backup?.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"] == 2)
    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fourFingerKey] == 0)
    #expect(store.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"]?[fourFingerKey] == 0)
}

@Test func disableRecordsAbsentKeyDistinctFromZero() {
    let store = FakeTrackpadPreferenceStore() // no keys set at all
    guard let backup = ConflictingGestureManager.disable(fingerCount: 5, store: store) else {
        Issue.record("disable returned nil")
        return
    }

    // The dictionary must record an entry for the domain (present), whose
    // inner value is nil (the key genuinely didn't exist before) — distinct
    // from the domain being absent from the dictionary entirely.
    switch backup.values["com.apple.AppleMultitouchTrackpad"] {
    case .some(.none):
        break
    default:
        Issue.record("expected a present-but-nil backup entry, got \(String(describing: backup.values["com.apple.AppleMultitouchTrackpad"]))")
    }
    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fiveFingerKey] == 0)
}

@Test func restoreWritesBackExactOriginalValues() {
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 0],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 0]
    ])
    let backup = GestureConflictBackup(fingerCount: 4, values: [
        "com.apple.AppleMultitouchTrackpad": 2,
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": 2
    ])
    ConflictingGestureManager.restore(backup, store: store)

    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fourFingerKey] == 2)
    #expect(store.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"]?[fourFingerKey] == 2)
}

@Test func restoreOfAbsentKeyDeletesRatherThanWritingZero() {
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 0]
    ])
    let backup = GestureConflictBackup(fingerCount: 4, values: [
        "com.apple.AppleMultitouchTrackpad": nil
    ])
    ConflictingGestureManager.restore(backup, store: store)

    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fourFingerKey] == nil)
}

@Test func disableThenRestoreRoundTripsToByteIdenticalStartingState() {
    let initial: [String: [String: Int]] = [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 2]
    ]
    let store = FakeTrackpadPreferenceStore(initialValues: initial)

    guard let backup = ConflictingGestureManager.disable(fingerCount: 4, store: store) else {
        Issue.record("disable returned nil")
        return
    }
    ConflictingGestureManager.restore(backup, store: store)

    #expect(store.values == initial)
}

@Test func onlyPinchKeysAreEverTouchedNeverSwipeKeys() {
    let store = FakeTrackpadPreferenceStore()
    if let backup = ConflictingGestureManager.disable(fingerCount: 4, store: store) {
        ConflictingGestureManager.restore(backup, store: store)
    }
    let allowed: Set<String> = [fourFingerKey, fiveFingerKey]
    #expect(store.touchedKeys.isSubset(of: allowed))
}
