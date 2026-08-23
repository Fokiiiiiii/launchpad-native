import Foundation
import OSLog

/// Packages the app's recent log history as a zip of one file per day.
///
/// The app stores nothing of its own: entries are read out of macOS's unified
/// log at export time, so there is no directory to grow or rotate. The 30-day
/// window is a query bound, not a retention policy — the system ages its own
/// store out. Reading past the current process needs
/// `OSLogStore(scope: .system)`, verified to work from the real bundle; if that
/// ever fails the export degrades to this session rather than erroring.
public enum DiagnosticsArchive {
    public struct Summary: Equatable, Sendable {
        public let dayCount: Int
        public let entryCount: Int
        public let byteCount: Int
        public let truncatedDays: Int
    }

    /// Days of history to request.
    public static let defaultDayCount = 30
    /// Backstop against a crash loop writing tens of thousands of lines, not a
    /// size target. At 600 it produced an unusable archive: a day with 736
    /// errors kept all of them and none of the surrounding notices, leaving no
    /// trace of what the app was doing. Errors without context are not a log.
    public static let defaultEntriesPerDay = 20_000
    /// Share of the cap held for routine entries even when errors alone would
    /// fill it. Errors are still never dropped; this stops them from crowding
    /// out the context that makes them readable.
    static let routineFloorFraction = 0.5

    /// Groups by local calendar day — the day a user names when reporting.
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

            // Errors survive unconditionally; the rest is kept newest-first up
            // to the remaining budget, then restored to time order.
            var keep = Set<Int>()
            var routine: [Int] = []
            for (index, line) in lines.enumerated() {
                if line.contains("[error]") || line.contains("[fault]") {
                    keep.insert(index)
                } else {
                    routine.append(index)
                }
            }
            // The floor keeps context alive on an error-heavy day.
            let routineFloor = Int(Double(entriesPerDay) * routineFloorFraction)
            let budget = max(entriesPerDay - keep.count, routineFloor)
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
    /// The zip comes from `NSFileCoordinator`'s `.forUploading` — Foundation's
    /// own, so no external tool or bundled compression library.
    @discardableResult
    public static func write(
        to destination: URL,
        days: Int = defaultDayCount,
        entriesPerDay: Int = defaultEntriesPerDay,
        now: Date = Date()
    ) throws -> Summary {
        let entries = readEntries(days: days, now: now)
        let grouped = groupByDay(entries, entriesPerDay: entriesPerDay)

        // The zip names its top-level folder after this directory, so the
        // unique part goes on the parent — the recipient sees no UUID.
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchpadnative-export-\(UUID().uuidString)")
        let staging = stagingRoot.appendingPathComponent("LaunchpadNative-logs")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        // So whoever opens the zip sees the build without opening a log.
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
