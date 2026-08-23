import Foundation
import Testing
@testable import Diagnostics

private func freshDefaults() -> UserDefaults {
    let suite = UserDefaults(suiteName: "crash-sentinel-\(UUID().uuidString)")!
    return suite
}

@Test func aFirstLaunchIsNotReportedAsACrash() {
    let defaults = freshDefaults()
    #expect(CrashSentinel.beginSession(version: "1.0", defaults: defaults) == .firstRun)
}

@Test func aCleanShutdownIsRememberedAsClean() {
    let defaults = freshDefaults()
    CrashSentinel.beginSession(version: "1.0", defaults: defaults)
    CrashSentinel.endSession(defaults: defaults)
    #expect(CrashSentinel.beginSession(version: "1.0", defaults: defaults) == .cleanExit)
}

/// The case this exists for: a run that never reached its shutdown path.
@Test func aRunThatNeverShutDownIsReportedWithItsVersion() {
    let defaults = freshDefaults()
    CrashSentinel.beginSession(version: "1.2.0", defaults: defaults)
    // No endSession — the process died here.
    #expect(CrashSentinel.beginSession(version: "1.3.0", defaults: defaults) == .unexpectedTermination(version: "1.2.0"))
}

/// Knowing *which* version died is what makes the signal actionable, so the
/// version recorded must be the one that was running, not the one starting up.
@Test func theReportedVersionIsTheOneThatDiedNotTheOneStarting() {
    let defaults = freshDefaults()
    CrashSentinel.beginSession(version: "2.0", defaults: defaults)
    guard case .unexpectedTermination(let version) = CrashSentinel.beginSession(version: "3.0", defaults: defaults) else {
        Issue.record("expected an unexpected termination")
        return
    }
    #expect(version == "2.0")
}

/// A crash must not be reported twice: the launch that noticed it has already
/// started its own session, so the one after that is clean unless it also dies.
@Test func aCrashIsReportedOnceNotForever() {
    let defaults = freshDefaults()
    CrashSentinel.beginSession(version: "1.0", defaults: defaults)
    _ = CrashSentinel.beginSession(version: "1.0", defaults: defaults) // notices the crash
    CrashSentinel.endSession(defaults: defaults)
    #expect(CrashSentinel.beginSession(version: "1.0", defaults: defaults) == .cleanExit)
}

/// Repeated crashes each get reported — the flag is re-armed every launch.
@Test func consecutiveCrashesAreEachReported() {
    let defaults = freshDefaults()
    CrashSentinel.beginSession(version: "1.0", defaults: defaults)
    #expect(CrashSentinel.beginSession(version: "1.0", defaults: defaults) == .unexpectedTermination(version: "1.0"))
    #expect(CrashSentinel.beginSession(version: "1.0", defaults: defaults) == .unexpectedTermination(version: "1.0"))
}
