import Foundation
import OSLog

/// Builds the text a user can attach to a bug report.
///
/// "It just disappears" and "the gesture stopped working" are unactionable on
/// their own, and asking someone to run `log stream` in Terminal is not a real
/// answer. This collects what would otherwise have to be asked for one question
/// at a time: which build, on which OS, and what the app itself logged.
///
/// Only this process's own log entries are readable — `OSLogStore` with
/// `.currentProcessIdentifier` needs no entitlement, while reading the wider
/// system store does. That also means the report covers the *current* run only:
/// a crash's own final moments are in macOS's crash report, not here.
public enum DiagnosticsReport {
    public struct Environment: Sendable {
        public let appVersion: String
        public let appBuild: String
        public let osVersion: String
        public let model: String
        public let generatedAt: Date
        /// How the run *before* this one ended. The single most useful line in
        /// a report about an app that "just disappears" — and it is not in the
        /// log, because the run that could have logged it is the one that died.
        public let previousSession: CrashSentinel.PreviousOutcome?

        public init(
            appVersion: String,
            appBuild: String,
            osVersion: String,
            model: String,
            generatedAt: Date,
            previousSession: CrashSentinel.PreviousOutcome? = nil
        ) {
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.osVersion = osVersion
            self.model = model
            self.generatedAt = generatedAt
            self.previousSession = previousSession
        }

        public static func current(
            bundle: Bundle = .main,
            now: Date = Date(),
            previousSession: CrashSentinel.PreviousOutcome? = CrashSentinel.lastObservedOutcome
        ) -> Environment {
            let info = bundle.infoDictionary
            var systemInfo = utsname()
            uname(&systemInfo)
            let model = withUnsafeBytes(of: &systemInfo.machine) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            return Environment(
                appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                appBuild: info?["CFBundleVersion"] as? String ?? "unknown",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                model: model,
                generatedAt: now,
                previousSession: previousSession
            )
        }
    }

    /// Assembles the report from parts that are already gathered, so the
    /// formatting is testable without a log store.
    public static func compose(environment: Environment, logLines: [String]) -> String {
        let formatter = ISO8601DateFormatter()
        var report = """
        LaunchpadNative diagnostics
        Generated: \(formatter.string(from: environment.generatedAt))
        App: \(environment.appVersion) (\(environment.appBuild))
        macOS: \(environment.osVersion)
        Model: \(environment.model)
        Previous session: \(describe(environment.previousSession))

        """

        // Errors first, because that is what anyone reading this looks for. The
        // full log follows for context; without the summary a real failure is
        // one line among hundreds of routine ones.
        let problems = logLines.filter { $0.contains("[error]") || $0.contains("[fault]") }
        if !problems.isEmpty {
            report += "\n— Errors and faults (\(problems.count)) —\n"
            report += problems.joined(separator: "\n")
            report += "\n"
        }

        if logLines.isEmpty {
            report += "\n— No log entries were available for this session —\n"
        } else {
            report += "\n— Log (\(logLines.count) entries, this session only) —\n"
            report += logLines.joined(separator: "\n")
            report += "\n"
        }
        return report
    }

    private static func describe(_ outcome: CrashSentinel.PreviousOutcome?) -> String {
        switch outcome {
        case .none: return "not recorded"
        case .firstRun: return "none — this is the first recorded run"
        case .cleanExit: return "exited normally"
        case .unexpectedTermination(let version):
            return "DID NOT SHUT DOWN CLEANLY (was running \(version))"
        }
    }

    /// This process's own log entries, oldest first, capped so a long-running
    /// session cannot produce a file nobody will read.
    public static func recentLogLines(limit: Int = 500) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(timeIntervalSinceLatestBoot: 0)
            let formatter = ISO8601DateFormatter()
            var lines: [String] = []
            for entry in try store.getEntries(at: position) {
                guard let logEntry = entry as? OSLogEntryLog,
                      logEntry.subsystem == DiagnosticsLog.subsystem else { continue }
                lines.append("\(formatter.string(from: logEntry.date)) [\(logEntry.category)] [\(logEntry.level.exportName)] \(logEntry.composedMessage)")
            }
            return Array(lines.suffix(limit))
        } catch {
            DiagnosticsLog.appHost.error("Diagnostics report could not read the log store: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public static func current(bundle: Bundle = .main, now: Date = Date(), limit: Int = 500) -> String {
        compose(environment: .current(bundle: bundle, now: now), logLines: recentLogLines(limit: limit))
    }
}
