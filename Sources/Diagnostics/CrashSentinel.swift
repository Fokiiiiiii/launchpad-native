import Foundation

/// Notices that the previous run ended without shutting down.
///
/// macOS's own crash reports never reach the app, so a build that crashes for
/// some users looks identical from the inside to one that does not. A flag set
/// while running and cleared on exit closes that gap: still set at the next
/// launch means the run before did not finish.
///
/// Deliberately not a signal handler — those run where almost nothing is safe
/// to call, and a wrong one turns a crash into a hang. This records the fact of
/// an unclean exit, not its contents.
public enum CrashSentinel {
    public enum PreviousOutcome: Equatable, Sendable {
        /// No previous run recorded — a first launch, or a fresh preferences store.
        case firstRun
        /// The previous run shut down through `applicationWillTerminate`.
        case cleanExit
        /// The previous run never got there. Carries the version it was running,
        /// which is what makes the report actionable — "it crashes on 1.2, not 1.1".
        case unexpectedTermination(version: String)
    }

    /// What `beginSession` saw at launch, kept so a diagnostics report written
    /// later in the run can state it. Reading the flag again would be useless —
    /// by then this session has already set it.
    public private(set) nonisolated(unsafe) static var lastObservedOutcome: PreviousOutcome?

    static let sessionKey = "com.launchpadnative.app.sessionInProgress"
    static let versionKey = "com.launchpadnative.app.sessionVersion"

    /// Records that a run started, and reports how the previous one ended.
    @discardableResult
    public static func beginSession(version: String, defaults: UserDefaults = .standard) -> PreviousOutcome {
        let outcome: PreviousOutcome
        if defaults.object(forKey: sessionKey) == nil {
            outcome = .firstRun
        } else if defaults.bool(forKey: sessionKey) {
            outcome = .unexpectedTermination(version: defaults.string(forKey: versionKey) ?? "unknown")
        } else {
            outcome = .cleanExit
        }

        lastObservedOutcome = outcome
        defaults.set(true, forKey: sessionKey)
        defaults.set(version, forKey: versionKey)

        switch outcome {
        case .firstRun:
            DiagnosticsLog.appHost.info("CrashSentinel: first recorded run")
        case .cleanExit:
            DiagnosticsLog.appHost.debug("CrashSentinel: previous run exited cleanly")
        case .unexpectedTermination(let previousVersion):
            DiagnosticsLog.appHost.error(
                "CrashSentinel: previous run of version \(previousVersion, privacy: .public) ended without shutting down"
            )
        }
        return outcome
    }

    /// Records a clean shutdown. Anything that skips this — a crash, a force
    /// quit, a kill — leaves the flag set for the next launch to find.
    public static func endSession(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: sessionKey)
    }
}
