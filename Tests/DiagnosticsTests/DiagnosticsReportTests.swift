import Foundation
import Testing
@testable import Diagnostics

private let environment = DiagnosticsReport.Environment(
    appVersion: "1.4.0",
    appBuild: "42",
    osVersion: "Version 26.5.1 (Build 25F80)",
    model: "Mac16,7",
    architecture: "arm64",
    generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
)

/// The report exists so a bug report arrives with the answers already in it.
@Test func theReportNamesTheBuildAndTheMachine() {
    let report = DiagnosticsReport.compose(environment: environment, logLines: ["one", "two"])
    #expect(report.contains("1.4.0"))
    #expect(report.contains("42"))
    #expect(report.contains("26.5.1"))
    #expect(report.contains("Mac16,7"))
}

@Test func theReportIncludesTheLogInOrder() {
    let report = DiagnosticsReport.compose(environment: environment, logLines: ["first", "second", "third"])
    let first = report.range(of: "first")
    let third = report.range(of: "third")
    #expect(first != nil && third != nil)
    if let first, let third { #expect(first.lowerBound < third.lowerBound) }
    #expect(report.contains("3 entries"))
}

/// An empty log is a normal outcome, not an error — the report still has to say
/// something rather than trailing off.
@Test func anEmptyLogStillProducesAUsableReport() {
    let report = DiagnosticsReport.compose(environment: environment, logLines: [])
    #expect(report.contains("No log entries"))
    #expect(report.contains("1.4.0"))
}

/// The header has to survive being read by a human at the top of a mail.
@Test func theReportStartsWithItsHeader() {
    let report = DiagnosticsReport.compose(environment: environment, logLines: ["x"])
    #expect(report.hasPrefix("LaunchpadNative diagnostics"))
}

/// Reading this process's own log needs no entitlement, so it must work in a
/// plain test process too — if this ever stops being true, the feature is gone
/// and the UI offering it would be lying.
@Test func theProcessCanReadItsOwnLog() throws {
    _ = try DiagnosticsReport.readCurrentProcessLog(limit: 200)
}

/// A log that cannot be read must leave the report usable, not throw or invent lines.
@Test func aFailedLogReadYieldsNoLines() {
    struct ReadFailure: Error {}
    let lines = DiagnosticsReport.recentLogLines(limit: 10) { _ in throw ReadFailure() }
    #expect(lines.isEmpty)
}

/// Only the newest lines are kept, in their original order.
@Test func aLogReadIsCappedToTheNewestLines() {
    let lines = DiagnosticsReport.recentLogLines(limit: 2) { _ in ["a", "b", "c"] }
    #expect(lines == ["b", "c"])
}

/// The architecture is reported on its own line, not in place of the model.
@Test func theReportNamesTheArchitectureSeparatelyFromTheModel() {
    let report = DiagnosticsReport.compose(environment: environment, logLines: [])
    #expect(report.contains("Model: Mac16,7"))
    #expect(report.contains("Architecture: arm64"))
}

@Test func theModelIdentifierIsNeverEmpty() {
    // Either the machine's identifier or the documented "unknown" fallback.
    #expect(!DiagnosticsReport.Environment.hardwareModelIdentifier().isEmpty)
}

@Test func theCurrentEnvironmentUsesTheGivenHardware() {
    let current = DiagnosticsReport.Environment.current(previousSession: nil, model: "Mac16,7", architecture: "arm64")
    #expect(current.model == "Mac16,7")
    #expect(current.architecture == "arm64")
}
