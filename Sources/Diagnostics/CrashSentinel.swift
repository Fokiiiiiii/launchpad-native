import Foundation

/// Notices that the previous run ended without shutting down.
///
/// macOS writes its own crash reports, but nothing in them reaches the app, so
/// a build that crashes for some users looks identical from the inside to one
/// that does not. This is the smallest thing that closes that gap: a flag set
/// while running and cleared on a clean exit. If it is still set at the next
/// launch, the run before this one did not finish — which is worth a log line,
/// and worth knowing when someone reports "it just disappears".
///
/// Deliberately not a signal handler. Handlers run in a context where almost
/// nothing is safe to call, and a wrong one turns a crash into a hang. This
/// records the *fact* of an unclean exit rather than trying to describe it.
public enum CrashSentinel {
    public enum PreviousOutcome: Equatable {
        /// No previous run recorded — a first launch, or a fresh preferences store.
        case firstRun
        /// The previous run shut down through `applicationWillTerminate`.
        case cleanExit
        /// The previous run never got there. Carries the version it was running,
        /// which is what makes the report actionable — "it crashes on 1.2, not 1.1".
        case unexpectedTermination(version: String)
    }

    static let sessionKey = "com.launchpadnative.app.sessionInProgress"
    static let versionKey = "com.launchpadnative.app.sessionVersion"

    /// Records that a run has started, and reports how the previous one ended.
    ///
    /// Synchronizes immediately: the whole point is to survive a process that
    /// never gets to exit, so the write cannot wait for a normal flush.
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
