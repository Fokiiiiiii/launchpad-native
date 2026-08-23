import Foundation
import Testing
@testable import Diagnostics

private let calendar = Calendar(identifier: .gregorian)

private func entry(_ day: String, _ hour: Int, _ text: String) -> (date: Date, line: String) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    let date = formatter.date(from: "\(day) \(String(format: "%02d", hour)):00")!
    return (date, text)
}

// MARK: grouping

/// One file per day is the whole shape of the archive: a user reporting "it
/// broke on Tuesday" should be able to open Tuesday.
@Test func entriesAreGroupedIntoOneFilePerCalendarDay() {
    let grouped = DiagnosticsArchive.groupByDay([
        entry("2026-08-20", 9, "a"),
        entry("2026-08-20", 23, "b"),
        entry("2026-08-21", 1, "c")
    ], calendar: calendar)

    #expect(grouped.count == 2)
    #expect(grouped[0].lines == ["a", "b"])
    #expect(grouped[1].lines == ["c"])
}

@Test func daysComeOutInChronologicalOrder() {
    let grouped = DiagnosticsArchive.groupByDay([
        entry("2026-08-22", 9, "third"),
        entry("2026-08-20", 9, "first"),
        entry("2026-08-21", 9, "second")
    ], calendar: calendar)
    #expect(grouped.map(\.lines) == [["first"], ["second"], ["third"]])
}

/// A crash loop can write thousands of lines in a day. The cap keeps a report
/// meant to be a few kilobytes from becoming megabytes.
@Test func anOverlongDayIsCappedAndSaysSo() {
    let noisy = (0..<50).map { entry("2026-08-20", 9, "[notice] line \($0)") }
    let grouped = DiagnosticsArchive.groupByDay(noisy, calendar: calendar, entriesPerDay: 10)

    #expect(grouped.count == 1)
    #expect(grouped[0].lines.count == 10)
    #expect(grouped[0].truncated == 40)
    // The *newest* entries survive: the end of a bad day is where the failure is.
    #expect(grouped[0].lines.last == "[notice] line 49")
}

/// Errors are why anyone opens the archive. Trimming a noisy day must not drop
/// them to hit a size target — the routine entries around them give way instead.
@Test func errorsSurviveTheCapEvenOnANoisyDay() {
    var entries = (0..<200).map { entry("2026-08-20", 9, "[notice] routine \($0)") }
    entries.insert(entry("2026-08-20", 8, "[error] the thing that broke"), at: 0)
    entries.append(entry("2026-08-20", 23, "[fault] and the crash"))

    let grouped = DiagnosticsArchive.groupByDay(entries, calendar: calendar, entriesPerDay: 10)
    let kept = grouped[0].lines
    #expect(kept.contains("[error] the thing that broke"))
    #expect(kept.contains("[fault] and the crash"))
    #expect(kept.count <= 12, "kept \(kept.count)")
}

/// What survives has to stay in time order — an error kept from the morning
/// belongs before the evening entries, not appended after them.
@Test func theKeptEntriesRemainInChronologicalOrder() {
    var entries = (0..<40).map { entry("2026-08-20", 12, "[notice] routine \($0)") }
    entries.insert(entry("2026-08-20", 8, "[error] early failure"), at: 0)

    let kept = DiagnosticsArchive.groupByDay(entries, calendar: calendar, entriesPerDay: 5)[0].lines
    #expect(kept.first == "[error] early failure")
}

@Test func aDayWithinTheCapIsNotMarkedTruncated() {
    let grouped = DiagnosticsArchive.groupByDay(
        [entry("2026-08-20", 9, "only")], calendar: calendar, entriesPerDay: 10
    )
    #expect(grouped[0].truncated == 0)
}

@Test func fileNamesAreSortableDates() {
    let day = calendar.startOfDay(for: entry("2026-08-20", 9, "x").date)
    #expect(DiagnosticsArchive.fileName(for: day) == "2026-08-20.log")
}

// MARK: archive

/// End to end against the real log store and a real zip.
@Test func writingAnArchiveProducesAZipContainingDailyLogs() throws {
    DiagnosticsLog.appHost.notice("archive test marker")
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("logs-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: destination) }

    let summary = try DiagnosticsArchive.write(to: destination, days: 30)

    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(summary.byteCount > 0)
    // The intent is an attachment, not a disk image: flag if it ever balloons.
    #expect(summary.byteCount < 5_000_000, "archive grew to \(summary.byteCount) bytes")

    // It is a real zip: the local file header magic is the first four bytes.
    let handle = try FileHandle(forReadingFrom: destination)
    defer { try? handle.close() }
    let magic = try #require(try handle.read(upToCount: 4))
    #expect(Array(magic) == [0x50, 0x4B, 0x03, 0x04], "not a zip archive")
}

/// Exporting twice in a row must overwrite rather than fail on an existing file.
@Test func writingTwiceReplacesTheExistingArchive() throws {
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("logs-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: destination) }

    _ = try DiagnosticsArchive.write(to: destination, days: 1)
    let second = try DiagnosticsArchive.write(to: destination, days: 1)
    #expect(second.byteCount > 0)
}

/// Nothing is kept between exports — the archive is built from the system's own
/// log store, so the app has no log directory to grow or rotate.
@Test func theAppKeepsNoLogFilesOfItsOwn() {
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    let logDirectory = library?.appendingPathComponent("Logs/LaunchpadNative")
    #expect(
        logDirectory.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true,
        "the app should not be accumulating its own log directory"
    )
}
