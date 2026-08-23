import Foundation
import OSLog

/// Packages the app's recent log history as a zip of one file per day.
///
/// **The app stores nothing of its own.** Entries are read back out of macOS's
/// own unified log at export time, so there is no log directory growing in the
/// user's Library, nothing to rotate, and no disk cost between exports. The
/// thirty-day window is a query bound, not a retention policy this app
/// implements — the system already ages its store out, and asking for more than
/// it kept simply returns less.
///
/// Reading beyond the current process needs `OSLogStore(scope: .system)`, which
/// was verified to work from the real app bundle. If it ever stops working the
/// export degrades to this session only rather than failing.
public enum DiagnosticsArchive {
    public struct Summary: Equatable, Sendable {
        public let dayCount: Int
        public let entryCount: Int
        public let byteCount: Int
        public let truncatedDays: Int
    }

    /// Days of history to request.
    public static let defaultDayCount = 30
    /// Per-day cap. Keeps a pathological day (a crash loop writing thousands of
    /// lines) from turning a report meant to be a few kilobytes into megabytes.
    /// Truncation is recorded in the file itself rather than hidden.
    ///
    /// Errors and faults are exempt: they are the reason anyone opens the
    /// archive, and dropping them to stay under a size target would defeat the
    /// point of the export. The cap applies to the routine entries around them.
    public static let defaultEntriesPerDay = 600

    /// Groups entries by calendar day in the local time zone — the day a user
    /// would name when saying "it broke on Tuesday".
    static func groupByDay(
        _ entries: [(date: Date, line: String)],
        calendar: Calendar = .current,
        entriesPerDay: Int = defaultEntriesPerDay
    ) -> [(day: Date, lines: [String], truncated: Int)] {
        var byDay: [Date: [String]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            byDay[day, default: []].append(entry.line)
        }
        return byDay.keys.sorted().map { day in
            let lines = byDay[day] ?? []
            guard lines.count > entriesPerDay else { return (day, lines, 0) }

            // Errors survive the cap unconditionally. Everything else is kept
            // newest-first up to the remaining budget — the end of a bad day is
            // where the failure is — and the result is put back in time order,
            // because a log read out of sequence is barely a log.
            var keep = Set<Int>()
            var routine: [Int] = []
            for (index, line) in lines.enumerated() {
                if line.contains("[error]") || line.contains("[fault]") {
                    keep.insert(index)
                } else {
                    routine.append(index)
                }
            }
            let budget = max(entriesPerDay - keep.count, 0)
            keep.formUnion(routine.suffix(budget))
            let kept = lines.enumerated().filter { keep.contains($0.offset) }.map(\.element)
            return (day, kept, lines.count - kept.count)
        }
    }

    static func fileName(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: day)).log"
    }

    /// Reads this app's entries from the unified log, newest window first.
    static func readEntries(days: Int, now: Date = Date()) -> [(date: Date, line: String)] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]

        func collect(from store: OSLogStore) throws -> [(date: Date, line: String)] {
            let position = store.position(date: since)
            let predicate = NSPredicate(format: "subsystem == %@", DiagnosticsLog.subsystem)
            var collected: [(date: Date, line: String)] = []
            for entry in try store.getEntries(at: position, matching: predicate) {
                guard let log = entry as? OSLogEntryLog else { continue }
                collected.append((
                    log.date,
                    "\(formatter.string(from: log.date)) [\(log.category)] [\(levelName(log.level))] \(log.composedMessage)"
                ))
            }
            return collected
        }

        do {
            return try collect(from: OSLogStore(scope: .system))
        } catch {
            DiagnosticsLog.appHost.error(
                "Log archive could not read the system store (\(error.localizedDescription, privacy: .public)); falling back to this session"
            )
            return (try? collect(from: OSLogStore(scope: .currentProcessIdentifier))) ?? []
        }
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "undefined"
        @unknown default: return "unknown"
        }
    }

    /// Writes the archive to `destination`, replacing anything already there.
    ///
    /// The zip is built by `NSFileCoordinator`'s `.forUploading` option, which
    /// is Foundation's own way to produce one — no external tool, no bundled
    /// compression library.
    @discardableResult
    public static func write(
        to destination: URL,
        days: Int = defaultDayCount,
        entriesPerDay: Int = defaultEntriesPerDay,
        now: Date = Date()
    ) throws -> Summary {
        let entries = readEntries(days: days, now: now)
        let grouped = groupByDay(entries, entriesPerDay: entriesPerDay)

        // The zip takes its top-level folder name from this directory, so the
        // unique part goes on its *parent*: someone opening the archive sees
        // "LaunchpadNative-logs", not a UUID.
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchpadnative-export-\(UUID().uuidString)")
        let staging = stagingRoot.appendingPathComponent("LaunchpadNative-logs")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        // A summary alongside the days, so whoever opens the zip knows what
        // build produced it without opening a log file.
        let environment = DiagnosticsReport.Environment.current(now: now)
        try DiagnosticsReport.compose(environment: environment, logLines: [])
            .write(to: staging.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)

        var entryCount = 0
        var truncatedDays = 0
        for (day, lines, truncated) in grouped {
            entryCount += lines.count
            var contents = lines.joined(separator: "\n")
            if truncated > 0 {
                truncatedDays += 1
                contents = "— \(truncated) earlier entries from this day omitted —\n" + contents
            }
            try (contents + "\n").write(
                to: staging.appendingPathComponent(fileName(for: day)),
                atomically: true,
                encoding: .utf8
            )
        }

        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: staging,
            options: [.forUploading],
            error: &coordinatorError
        ) { zipped in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }

        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let byteCount = (attributes?[.size] as? Int) ?? 0
        return Summary(
            dayCount: grouped.count,
            entryCount: entryCount,
            byteCount: byteCount,
            truncatedDays: truncatedDays
        )
    }
}
