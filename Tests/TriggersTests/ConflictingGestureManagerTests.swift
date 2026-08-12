import Foundation
import Persistence
import Testing
@testable import Triggers

private final class FakeTrackpadPreferenceStore: TrackpadPreferenceStore {
    private(set) var values: [String: [String: Int]] = [:]
    private(set) var touchedKeys: Set<String> = []
    private(set) var synchronizeCallCount = 0
    private var remainingSynchronizeFailures: [String: Int]
    private let ignoredWriteDomains: Set<String>

    init(
        initialValues: [String: [String: Int]] = [:],
        synchronizeFailures: [String: Int] = [:],
        ignoredWriteDomains: Set<String> = []
    ) {
        values = initialValues
        remainingSynchronizeFailures = synchronizeFailures
        self.ignoredWriteDomains = ignoredWriteDomains
    }

    func integerValue(forKey key: String, domain: String) -> Int? {
        values[domain]?[key]
    }

    func setIntegerValue(_ value: Int?, forKey key: String, domain: String) {
        touchedKeys.insert(key)
        guard !ignoredWriteDomains.contains(domain) else { return }
        if let value {
            values[domain, default: [:]][key] = value
        } else {
            values[domain]?.removeValue(forKey: key)
            if values[domain]?.isEmpty == true {
                values.removeValue(forKey: domain)
            }
        }
    }

    @discardableResult
    func synchronize(domain: String) -> Bool {
        synchronizeCallCount += 1
        if let remaining = remainingSynchronizeFailures[domain], remaining > 0 {
            remainingSynchronizeFailures[domain] = remaining - 1
            return false
        }
        return true
    }
}

private let fourFingerKey = "TrackpadFourFingerPinchGesture"
private let fiveFingerKey = "TrackpadFiveFingerPinchGesture"
private let fourFingerHorizSwipeKey = "TrackpadFourFingerHorizSwipeGesture"
private let fourFingerVertSwipeKey = "TrackpadFourFingerVertSwipeGesture"
private let fiveFingerHorizSwipeKey = "TrackpadFiveFingerHorizSwipeGesture"
private let fiveFingerVertSwipeKey = "TrackpadFiveFingerVertSwipeGesture"
private let launchpadGestureKey = "showLaunchpadGestureEnabled"
private let missionControlGestureKey = "showMissionControlGestureEnabled"
private let appExposeGestureKey = "showAppExposeGestureEnabled"
private let threeFingerHorizSwipeKey = "TrackpadThreeFingerHorizSwipeGesture"

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

@Test func decideTransitionMatrixIncludesMultitouchEnabledAndFingerChanges() {
    let backup = GestureConflictBackup(fingerCount: 4, values: [:])
    let rows: [(Bool, Bool, Int, GestureConflictBackup?, ConflictingGestureManager.Transition)] = [
        (false, false, 4, nil, .none),
        (false, true, 4, nil, .none),
        (true, false, 4, nil, .none),
        (true, true, 4, nil, .disable(fingerCount: 4, restoringFirst: nil)),
        (false, false, 4, backup, .restore(backup)),
        (false, true, 4, backup, .restore(backup)),
        (true, false, 4, backup, .restore(backup)),
        (true, true, 4, backup, .none),
        (true, true, 5, backup, .disable(fingerCount: 5, restoringFirst: backup))
    ]

    for (enabled, multitouchEnabled, fingerCount, existingBackup, expected) in rows {
        let actual = ConflictingGestureManager.decideTransition(
            enabled: enabled,
            desiredFingerCount: fingerCount,
            existingBackup: existingBackup,
            multitouchEnabled: multitouchEnabled
        )
        #expect(actual == expected)
    }
}

@Test func disableBacksUpExistingValueAcrossBothDomainsAndWritesZero() {
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2, fiveFingerKey: 1],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 2, fiveFingerKey: 1]
    ])
    let backup = ConflictingGestureManager.disable(fingerCount: 4, store: store)

    #expect(backup?.fingerCount == 4)
    #expect(backup?.values["com.apple.AppleMultitouchTrackpad"] == 2)
    #expect(backup?.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"] == 2)
    #expect(backup?.valuesByFingerCount?[5]?["com.apple.AppleMultitouchTrackpad"] == 1)
    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fourFingerKey] == 0)
    #expect(store.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"]?[fourFingerKey] == 0)
    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fiveFingerKey] == 0)
    #expect(store.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"]?[fiveFingerKey] == 0)
}

@Test func bothPinchKeysRestoreExactlyAfterDisable() {
    let initial: [String: [String: Int]] = [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2, fiveFingerKey: 1],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 0, fiveFingerKey: 3]
    ]
    let store = FakeTrackpadPreferenceStore(initialValues: initial)

    guard let backup = ConflictingGestureManager.disable(fingerCount: 5, store: store) else {
        Issue.record("disable returned nil")
        return
    }
    #expect(ConflictingGestureManager.domains.allSatisfy { domain in
        let values = store.values[domain] ?? [:]
        return values[fourFingerKey] == 0 && values[fiveFingerKey] == 0
    })
    #expect(ConflictingGestureManager.restore(backup, store: store))
    #expect(store.values == initial)
}

@Test func bothKeyDisableFailureRollsBackEveryKeyAndDomain() {
    let initial: [String: [String: Int]] = [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2, fiveFingerKey: 1],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 0, fiveFingerKey: 3]
    ]
    let failingDomain = "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    let store = FakeTrackpadPreferenceStore(
        initialValues: initial,
        synchronizeFailures: [failingDomain: 1]
    )

    #expect(ConflictingGestureManager.disableVerified(fingerCount: 4, store: store) == .failed)
    #expect(store.values == initial)
}

@Test func dockGestureDisableFailureRollsBackTrackpadNavigationChanges() {
    let initial: [String: [String: Int]] = [
        "com.apple.AppleMultitouchTrackpad": [
            fourFingerKey: 2,
            fiveFingerKey: 2,
            fourFingerHorizSwipeKey: 2,
            fourFingerVertSwipeKey: 2
        ],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [
            fourFingerKey: 2,
            fiveFingerKey: 2,
            fourFingerHorizSwipeKey: 2,
            fourFingerVertSwipeKey: 2
        ],
        ConflictingGestureManager.launchpadDomain: [
            launchpadGestureKey: 1,
            missionControlGestureKey: 1,
            appExposeGestureKey: 1
        ]
    ]
    let store = FakeTrackpadPreferenceStore(
        initialValues: initial,
        synchronizeFailures: [ConflictingGestureManager.launchpadDomain: 1]
    )

    #expect(ConflictingGestureManager.disableVerified(fingerCount: 4, store: store) == .failed)
    #expect(store.values == initial)
}

@Test func legacyBackupCodableRoundTripsWithoutNewMap() throws {
    let data = Data("""
    {"fingerCount":4,"values":{"com.apple.AppleMultitouchTrackpad":2,"com.apple.driver.AppleBluetoothMultitouch.trackpad":1}}
    """.utf8)
    let decoded = try JSONDecoder().decode(GestureConflictBackup.self, from: data)

    #expect(decoded.fingerCount == 4)
    #expect(decoded.valuesByFingerCount == nil)
    let encoded = try JSONEncoder().encode(decoded)
    let roundTrip = try JSONDecoder().decode(GestureConflictBackup.self, from: encoded)
    #expect(roundTrip == decoded)
}

@Test func capturedAbsentLaunchpadPreferenceSurvivesCodableRoundTrip() throws {
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 2]
    ])
    guard let backup = ConflictingGestureManager.disable(fingerCount: 4, store: store) else {
        Issue.record("disable returned nil")
        return
    }
    let roundTrip = try JSONDecoder().decode(
        GestureConflictBackup.self,
        from: JSONEncoder().encode(backup)
    )
    #expect(roundTrip.launchpadGestureCaptured)
    #expect(!roundTrip.launchpadGestureWasPresent)
    #expect(roundTrip.launchpadGestureValue == nil)
    #expect(ConflictingGestureManager.restore(roundTrip, store: store))
    #expect(store.values[ConflictingGestureManager.launchpadDomain] == nil)
}

@Test func legacyBackupDoesNotTouchUntrackedDockPreference() {
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 0],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 0],
        ConflictingGestureManager.launchpadDomain: [launchpadGestureKey: 1]
    ])
    let legacy = GestureConflictBackup(fingerCount: 4, values: [
        "com.apple.AppleMultitouchTrackpad": 2,
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": 2
    ])

    #expect(ConflictingGestureManager.restore(legacy, store: store))
    #expect(store.values[ConflictingGestureManager.launchpadDomain]?[launchpadGestureKey] == 1)
    #expect(!store.touchedKeys.contains(launchpadGestureKey))
}

@Test func reapplyKeepsCapturedAbsentDockPreferenceAsAbsent() {
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2, fiveFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 2, fiveFingerKey: 2]
    ])
    guard let original = ConflictingGestureManager.captureBackup(fingerCount: 4, store: store) else {
        Issue.record("capture returned nil")
        return
    }
    store.setIntegerValue(0, forKey: launchpadGestureKey, domain: ConflictingGestureManager.launchpadDomain)

    guard case .succeeded(let reapplied) = ConflictingGestureManager.disableVerified(
        fingerCount: 4,
        store: store,
        preserving: original
    ) else {
        Issue.record("reapply returned failure")
        return
    }
    #expect(reapplied.launchpadGestureCaptured)
    #expect(!reapplied.launchpadGestureWasPresent)
    #expect(ConflictingGestureManager.restore(reapplied, store: store))
    #expect(store.values[ConflictingGestureManager.launchpadDomain] == nil)
}

@Test func disableRejectsUnsupportedFingerCountWithoutWriting() {
    let initial: [String: [String: Int]] = [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 2]
    ]
    let store = FakeTrackpadPreferenceStore(initialValues: initial)

    #expect(ConflictingGestureManager.disableVerified(fingerCount: 3, store: store) == .failed)
    #expect(store.values == initial)
    #expect(store.touchedKeys.isEmpty)
}

@Test func captureBackupIsReadOnlyAndCoversBothDomains() {
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 1]
    ])

    let backup = ConflictingGestureManager.captureBackup(fingerCount: 4, store: store)

    #expect(backup?.values["com.apple.AppleMultitouchTrackpad"] == 2)
    #expect(backup?.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"] == 1)
    #expect(backup.map(ConflictingGestureManager.isCompleteRestorePoint) == true)
    #expect(store.touchedKeys.isEmpty)
    #expect(store.synchronizeCallCount == 0)
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

@Test func disableRewritesAlreadyDisabledCompetingKeysToNotifySystemConsumers() {
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 0, fiveFingerKey: 0],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 0, fiveFingerKey: 0]
    ])

    #expect(ConflictingGestureManager.disableVerified(fingerCount: 4, store: store) != .failed)
    #expect(store.touchedKeys == Set([fourFingerKey, fiveFingerKey]))
    #expect(store.synchronizeCallCount == ConflictingGestureManager.domains.count * 2)
}

@Test func selectedFingerCountLeavesSiblingPinchKeyUntouched() {
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2, fiveFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 2, fiveFingerKey: 2]
    ])

    #expect(ConflictingGestureManager.disableVerified(
        fingerCount: 4,
        store: store,
        disableBothFingerCounts: false,
        disableRelatedNavigation: false
    ) != .failed)
    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fourFingerKey] == 0)
    #expect(store.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"]?[fourFingerKey] == 0)
    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fiveFingerKey] == 2)
    #expect(store.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"]?[fiveFingerKey] == 2)
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
        "com.apple.AppleMultitouchTrackpad": nil,
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": nil
    ])
    ConflictingGestureManager.restore(backup, store: store)

    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fourFingerKey] == nil)
}

@Test func restoreRejectsIncompleteBackupWithoutTouchingPreferences() {
    let initial: [String: [String: Int]] = [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 0],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 0]
    ]
    let store = FakeTrackpadPreferenceStore(initialValues: initial)
    let backup = GestureConflictBackup(fingerCount: 4, values: [
        "com.apple.AppleMultitouchTrackpad": 2
    ])

    #expect(!ConflictingGestureManager.restore(backup, store: store))
    #expect(store.values == initial)
    #expect(store.synchronizeCallCount == 0)
}

@Test func reapplyPreservesRestorePointWhenExternalUserReenablesGesture() {
    let restorePoint = GestureConflictBackup(fingerCount: 4, values: [
        "com.apple.AppleMultitouchTrackpad": 2,
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": 2
    ])
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 1, fiveFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 0, fiveFingerKey: 3]
    ])

    let result = ConflictingGestureManager.disableVerified(
        fingerCount: 4,
        store: store,
        preserving: restorePoint
    )

    guard case .succeeded(let upgradedBackup) = result else {
        Issue.record("disable did not return a restore point")
        return
    }
    #expect(upgradedBackup.fingerCount == restorePoint.fingerCount)
    #expect(upgradedBackup.values == restorePoint.values)
    let upgradedFingerCounts = upgradedBackup.valuesByFingerCount.map { Set($0.keys) } ?? []
    #expect(upgradedFingerCounts == Set([4, 5]))
    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fourFingerKey] == 0)
    #expect(store.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"]?[fourFingerKey] == 0)
    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fiveFingerKey] == 0)
    #expect(store.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"]?[fiveFingerKey] == 0)
}

@Test func oldRestorePointRemainsUsableAfterInterruptedFingerSwitch() {
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2, fiveFingerKey: 1],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 2, fiveFingerKey: 1]
    ])
    guard let oldBackup = ConflictingGestureManager.captureBackup(fingerCount: 4, store: store) else {
        Issue.record("could not capture the old finger-count restore point")
        return
    }

    // Simulate the runtime half of a 4 -> 5 switch completing after the old
    // key was restored, but before the new settings document was committed.
    #expect(ConflictingGestureManager.disableVerified(fingerCount: 4, store: store) != .failed)
    #expect(ConflictingGestureManager.restore(oldBackup, store: store))
    #expect(ConflictingGestureManager.disableVerified(fingerCount: 5, store: store) != .failed)

    // A crash at this point leaves the old document on disk. Startup must be
    // able to use that old backup again rather than treating it as stale or
    // incomplete.
    let startupReapply = ConflictingGestureManager.disableVerified(
        fingerCount: 4,
        store: store,
        preserving: oldBackup
    )
    #expect(startupReapply == .succeeded(oldBackup))
    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fourFingerKey] == 0)
    #expect(store.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"]?[fourFingerKey] == 0)
}

@Test func disableReadbackFailureRollsBackEveryDomainAndReturnsNoBackup() {
    let initial: [String: [String: Int]] = [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 2]
    ]
    let store = FakeTrackpadPreferenceStore(
        initialValues: initial,
        ignoredWriteDomains: ["com.apple.AppleMultitouchTrackpad"]
    )

    let result = ConflictingGestureManager.disableVerified(fingerCount: 4, store: store)

    #expect(result == .failed)
    #expect(store.values == initial)
}

@Test func disableSynchronizeFailureRollsBackEarlierAndFailedDomain() {
    let initial: [String: [String: Int]] = [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 1]
    ]
    let failingDomain = "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    let store = FakeTrackpadPreferenceStore(
        initialValues: initial,
        synchronizeFailures: [failingDomain: 1]
    )

    let result = ConflictingGestureManager.disableVerified(fingerCount: 4, store: store)

    #expect(result == .failed)
    #expect(store.values == initial)
}

@Test func restoreReportsReadbackFailureInsteadOfClaimingSuccess() {
    let store = FakeTrackpadPreferenceStore(
        initialValues: [
            "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 0],
            "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 0]
        ],
        ignoredWriteDomains: ["com.apple.driver.AppleBluetoothMultitouch.trackpad"]
    )
    let backup = GestureConflictBackup(fingerCount: 4, values: [
        "com.apple.AppleMultitouchTrackpad": 2,
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": 2
    ])

    let restored = ConflictingGestureManager.restore(backup, store: store)

    #expect(!restored)
    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fourFingerKey] == 2)
    #expect(store.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"]?[fourFingerKey] == 0)
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

@Test func competingFourFiveFingerKeysAreTouchedButThreeFingerSwipeIsNot() {
    let store = FakeTrackpadPreferenceStore()
    if let backup = ConflictingGestureManager.disable(fingerCount: 4, store: store) {
        ConflictingGestureManager.restore(backup, store: store)
    }
    let allowed: Set<String> = Set(
        [fourFingerKey, fiveFingerKey]
            + ConflictingGestureManager.trackpadSwipeKeys
            + ConflictingGestureManager.dockGestureKeys
    )
    #expect(store.touchedKeys.isSubset(of: allowed))
    #expect(!store.touchedKeys.contains(threeFingerHorizSwipeKey))
}

@Test func nativeDockGesturesAreDisabledAndRestoredExactly() {
    let initial: [String: [String: Int]] = [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2, fiveFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 2, fiveFingerKey: 2],
        ConflictingGestureManager.launchpadDomain: [
            launchpadGestureKey: 1,
            missionControlGestureKey: 1,
            appExposeGestureKey: 1
        ]
    ]
    let store = FakeTrackpadPreferenceStore(initialValues: initial)

    guard let backup = ConflictingGestureManager.disable(fingerCount: 4, store: store) else {
        Issue.record("disable returned nil")
        return
    }
    #expect(store.values[ConflictingGestureManager.launchpadDomain]?[launchpadGestureKey] == 0)
    #expect(store.values[ConflictingGestureManager.launchpadDomain]?[missionControlGestureKey] == 0)
    #expect(store.values[ConflictingGestureManager.launchpadDomain]?[appExposeGestureKey] == 0)
    #expect(backup.launchpadGestureWasPresent)
    #expect(backup.launchpadGestureValue == 1)
    #expect(backup.launchpadGestureCaptured)
    #expect(ConflictingGestureManager.restore(backup, store: store))
    #expect(store.values == initial)
}

@Test func competingNavigationGesturesAreDisabledWithoutTouchingThreeFingerSwipe() {
    let initial: [String: [String: Int]] = [
        "com.apple.AppleMultitouchTrackpad": [
            fourFingerKey: 2,
            fiveFingerKey: 2,
            fourFingerHorizSwipeKey: 2,
            fourFingerVertSwipeKey: 2,
            threeFingerHorizSwipeKey: 2
        ],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [
            fourFingerKey: 1,
            fiveFingerKey: 1,
            fourFingerHorizSwipeKey: 2,
            fourFingerVertSwipeKey: 2,
            threeFingerHorizSwipeKey: 2
        ],
        ConflictingGestureManager.launchpadDomain: [
            launchpadGestureKey: 1,
            missionControlGestureKey: 1,
            appExposeGestureKey: 1
        ]
    ]
    let store = FakeTrackpadPreferenceStore(initialValues: initial)

    guard let backup = ConflictingGestureManager.disable(fingerCount: 4, store: store) else {
        Issue.record("disable returned nil")
        return
    }
    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fourFingerHorizSwipeKey] == 0)
    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fourFingerVertSwipeKey] == 0)
    #expect(store.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"]?[fourFingerHorizSwipeKey] == 0)
    #expect(store.values[ConflictingGestureManager.launchpadDomain]?[missionControlGestureKey] == 0)
    #expect(store.values[ConflictingGestureManager.launchpadDomain]?[appExposeGestureKey] == 0)
    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[threeFingerHorizSwipeKey] == 2)
    #expect(ConflictingGestureManager.restore(backup, store: store))
    #expect(store.values == initial)
}

@Test @MainActor func coordinatorStopAllRestoresActiveGestureConflictBackup() {
    let initial: [String: [String: Int]] = [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 2]
    ]
    let store = FakeTrackpadPreferenceStore(initialValues: initial)
    let coordinator = TriggerCoordinator(
        onActivate: {},
        onPinchClose: {},
        onSpreadOpen: {},
        trackpadPreferenceStore: store
    )
    let settings = TriggerSettings(
        hotkeyEnabled: false,
        hotkeyKeyCode: nil,
        hotkeyModifierFlags: 0,
        hotCornersEnabled: [:],
        f4Enabled: false,
        multitouchGestureEnabled: true,
        multitouchSensitivity: 0.5,
        multitouchFingerCount: 4,
        gestureConflictPreventionEnabled: true,
        gestureConflictBackup: nil
    )

    let report = coordinator.apply(settings)
    if report.multitouchActive {
        guard case .updated = report.gestureConflictUpdate else {
            Issue.record("expected a persisted gesture conflict backup")
            coordinator.stopAll()
            return
        }
        #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fourFingerKey] == 0)
    } else {
        // This checkout may not have a usable MultitouchSupport device. The
        // coordinator must restore the preference when listener startup fails.
        #expect(report.gestureConflictUpdate == .failed)
    }

    coordinator.stopAll()

    #expect(store.values == initial)
}

@Test @MainActor func coordinatorDoesNotStartListenerWhenConflictDisableFails() {
    let initial: [String: [String: Int]] = [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 2]
    ]
    let store = FakeTrackpadPreferenceStore(
        initialValues: initial,
        ignoredWriteDomains: ["com.apple.AppleMultitouchTrackpad"]
    )
    let coordinator = TriggerCoordinator(
        onActivate: {},
        onPinchClose: {},
        onSpreadOpen: {},
        trackpadPreferenceStore: store
    )
    let settings = TriggerSettings(
        hotkeyEnabled: false,
        hotkeyKeyCode: nil,
        hotkeyModifierFlags: 0,
        hotCornersEnabled: [:],
        f4Enabled: false,
        multitouchGestureEnabled: true,
        multitouchSensitivity: 0.5,
        multitouchFingerCount: 4,
        gestureConflictPreventionEnabled: true,
        gestureConflictBackup: nil
    )

    let report = coordinator.apply(settings)

    #expect(report.gestureConflictUpdate == .failed)
    #expect(!report.multitouchActive)
    #expect(store.values == initial)
    coordinator.stopAll()
}

@Test @MainActor func coordinatorTreatsMultitouchAsConflictOwnerEvenWithLegacyOptOut() {
    let initial: [String: [String: Int]] = [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2, fiveFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 2, fiveFingerKey: 2]
    ]
    let store = FakeTrackpadPreferenceStore(initialValues: initial)
    let coordinator = TriggerCoordinator(
        onActivate: {},
        onPinchClose: {},
        onSpreadOpen: {},
        trackpadPreferenceStore: store
    )
    let settings = TriggerSettings(
        hotkeyEnabled: false,
        hotkeyKeyCode: nil,
        hotkeyModifierFlags: 0,
        hotCornersEnabled: [:],
        f4Enabled: false,
        multitouchGestureEnabled: true,
        multitouchSensitivity: 0.5,
        multitouchFingerCount: 4,
        gestureConflictPreventionEnabled: false,
        gestureConflictBackup: nil
    )

    let report = coordinator.apply(settings)

    #expect(store.touchedKeys.contains(fourFingerKey))
    #expect(!store.touchedKeys.contains(fiveFingerKey))
    #expect(report.gestureConflictUpdate != .unchanged)
    coordinator.stopAll()
    #expect(store.values == initial)
}

@Test @MainActor func coordinatorIgnoresStaleCandidateBeforeAnySideEffect() {
    let store = FakeTrackpadPreferenceStore()
    let coordinator = TriggerCoordinator(
        onActivate: {},
        onPinchClose: {},
        onSpreadOpen: {},
        trackpadPreferenceStore: store
    )
    let newerSettings = TriggerSettings(
        hotkeyEnabled: false,
        hotkeyKeyCode: nil,
        hotkeyModifierFlags: 0,
        hotCornersEnabled: [:],
        f4Enabled: false,
        multitouchGestureEnabled: false,
        multitouchSensitivity: 0.5,
        multitouchFingerCount: 5,
        gestureConflictPreventionEnabled: false,
        gestureConflictBackup: nil
    )
    let staleSettings = TriggerSettings(
        hotkeyEnabled: false,
        hotkeyKeyCode: nil,
        hotkeyModifierFlags: 0,
        hotCornersEnabled: [:],
        f4Enabled: false,
        multitouchGestureEnabled: true,
        multitouchSensitivity: 0.5,
        multitouchFingerCount: 4,
        gestureConflictPreventionEnabled: true,
        gestureConflictBackup: nil
    )

    _ = coordinator.apply(newerSettings, candidateToken: 2)
    let staleReport = coordinator.apply(staleSettings, candidateToken: 1)

    #expect(staleReport.gestureConflictUpdate == .unchanged)
    #expect(store.touchedKeys.isEmpty)
    #expect(store.synchronizeCallCount == 0)
}

@Test @MainActor func coordinatorPrepareRestorePointCapturesBeforeApply() {
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 2],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 1]
    ])
    let coordinator = TriggerCoordinator(
        onActivate: {},
        onPinchClose: {},
        onSpreadOpen: {},
        trackpadPreferenceStore: store
    )
    let settings = TriggerSettings(
        hotkeyEnabled: false,
        hotkeyKeyCode: nil,
        hotkeyModifierFlags: 0,
        hotCornersEnabled: [:],
        f4Enabled: false,
        multitouchGestureEnabled: true,
        multitouchSensitivity: 0.5,
        multitouchFingerCount: 4,
        gestureConflictPreventionEnabled: true,
        gestureConflictBackup: nil
    )

    let prepared = coordinator.prepareRestorePoint(for: settings)

    #expect(prepared?.gestureConflictBackup?.values["com.apple.AppleMultitouchTrackpad"] == 2)
    #expect(prepared?.gestureConflictBackup?.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"] == 1)
    let preparedFingerCounts = prepared?.gestureConflictBackup?.valuesByFingerCount.map { Set($0.keys) } ?? []
    #expect(preparedFingerCounts == Set([4, 5]))
    #expect(store.touchedKeys.isEmpty)
    #expect(store.synchronizeCallCount == 0)
}

@Test @MainActor func coordinatorUpgradesLegacyBackupBeforeApplyingBothKeys() {
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 0, fiveFingerKey: 1],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 0, fiveFingerKey: 2]
    ])
    let coordinator = TriggerCoordinator(
        onActivate: {},
        onPinchClose: {},
        onSpreadOpen: {},
        trackpadPreferenceStore: store
    )
    let legacyBackup = GestureConflictBackup(fingerCount: 4, values: [
        "com.apple.AppleMultitouchTrackpad": 3,
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": 4
    ])
    let settings = TriggerSettings(
        hotkeyEnabled: false,
        hotkeyKeyCode: nil,
        hotkeyModifierFlags: 0,
        hotCornersEnabled: [:],
        f4Enabled: false,
        multitouchGestureEnabled: true,
        multitouchSensitivity: 0.5,
        multitouchFingerCount: 4,
        gestureConflictPreventionEnabled: true,
        gestureConflictBackup: legacyBackup
    )

    let prepared = coordinator.prepareRestorePoint(for: settings)

    #expect(prepared?.gestureConflictBackup?.values == legacyBackup.values)
    #expect(prepared?.gestureConflictBackup?.valuesByFingerCount?[5]?["com.apple.AppleMultitouchTrackpad"] == 1)
    #expect(prepared?.gestureConflictBackup?.valuesByFingerCount?[5]?["com.apple.driver.AppleBluetoothMultitouch.trackpad"] == 2)
    #expect(prepared?.gestureConflictBackup?.trackpadGestureValues != nil)
    #expect(prepared?.gestureConflictBackup?.dockGesturesCaptured == true)
    #expect(store.touchedKeys.isEmpty)
}

@Test @MainActor func coordinatorRestoresFallbackBeforeFingerSwitchCapture() {
    let store = FakeTrackpadPreferenceStore(initialValues: [
        "com.apple.AppleMultitouchTrackpad": [fourFingerKey: 0, fiveFingerKey: 1],
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": [fourFingerKey: 0, fiveFingerKey: 1]
    ])
    let coordinator = TriggerCoordinator(
        onActivate: {},
        onPinchClose: {},
        onSpreadOpen: {},
        trackpadPreferenceStore: store
    )
    let oldBackup = GestureConflictBackup(fingerCount: 4, values: [
        "com.apple.AppleMultitouchTrackpad": 2,
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": 2
    ])

    #expect(coordinator.restoreGestureConflictForTransition(fallback: oldBackup))
    #expect(store.values["com.apple.AppleMultitouchTrackpad"]?[fourFingerKey] == 2)
    #expect(store.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"]?[fourFingerKey] == 2)

    let nextSettings = TriggerSettings(
        hotkeyEnabled: false,
        hotkeyKeyCode: nil,
        hotkeyModifierFlags: 0,
        hotCornersEnabled: [:],
        f4Enabled: false,
        multitouchGestureEnabled: true,
        multitouchSensitivity: 0.5,
        multitouchFingerCount: 5,
        gestureConflictPreventionEnabled: true,
        gestureConflictBackup: oldBackup
    )
    let prepared = coordinator.prepareRestorePoint(for: nextSettings)
    #expect(prepared?.gestureConflictBackup?.fingerCount == 5)
    #expect(prepared?.gestureConflictBackup?.values["com.apple.AppleMultitouchTrackpad"] == 1)
    #expect(prepared?.gestureConflictBackup?.values["com.apple.driver.AppleBluetoothMultitouch.trackpad"] == 1)
}
