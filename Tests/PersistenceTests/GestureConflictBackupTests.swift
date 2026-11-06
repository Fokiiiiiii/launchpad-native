import Foundation
import Testing
@testable import Persistence

@Test func theWrittenKeysSurviveASaveAndLoad() throws {
    let backup = GestureConflictBackup(
        fingerCount: 4,
        values: ["com.apple.AppleMultitouchTrackpad": 2],
        appliedKeys: ["com.apple.AppleMultitouchTrackpad|TrackpadFourFingerPinchGesture"]
    )

    let decoded = try JSONDecoder().decode(GestureConflictBackup.self, from: JSONEncoder().encode(backup))

    #expect(decoded == backup)
    #expect(decoded.appliedKeys == ["com.apple.AppleMultitouchTrackpad|TrackpadFourFingerPinchGesture"])
}

/// A restore point saved before the written keys were recorded has no such
/// field. It must still decode, and read as "unknown" rather than "none".
@Test func aRestorePointSavedBeforeTheyWereRecordedDecodesAsUnknown() throws {
    let legacy = Data(#"{"fingerCount":4,"values":{"com.apple.AppleMultitouchTrackpad":2}}"#.utf8)

    let decoded = try JSONDecoder().decode(GestureConflictBackup.self, from: legacy)

    #expect(decoded.appliedKeys == nil)
}
