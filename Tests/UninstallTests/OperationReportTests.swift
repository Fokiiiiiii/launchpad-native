import Foundation
import Testing
@testable import Uninstall

@Suite("OperationReport")
struct OperationReportTests {
    private func makeOutcome(succeeded: Bool, errorDescription: String?) -> RemovalOutcome {
        let item = RemovalItem(
            path: URL(fileURLWithPath: "/tmp/com.example.report-item"),
            classification: .unknown,
            requiresPrivilegedHelper: true
        )
        return RemovalOutcome(item: item, succeeded: succeeded, errorDescription: errorDescription)
    }

    @Test("execution outcomes preserve failure reasons in entries")
    func executionOutcomesPreserveFailureReasons() {
        let report = OperationReport(
            bundleIdentifier: "com.example.app",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            outcomes: [makeOutcome(succeeded: false, errorDescription: "manual removal required")]
        )

        #expect(report.entries.count == 1)
        #expect(report.entries[0].executed)
        #expect(report.entries[0].succeeded == false)
        #expect(report.entries[0].errorDescription == "manual removal required")
    }

    @Test("entries saved before errorDescription was added still decode")
    func oldEntriesDecodeWithNilFailureReason() throws {
        let report = OperationReport(
            bundleIdentifier: "com.example.app",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: [
                .init(
                    path: "/tmp/com.example.report-item",
                    classification: "unknown",
                    requiresPrivilegedHelper: true,
                    executed: true,
                    succeeded: false,
                    errorDescription: "manual removal required"
                )
            ]
        )
        let encoded = try JSONEncoder().encode(report)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var entries = try #require(json["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "errorDescription")
        json["entries"] = entries
        let oldData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(OperationReport.self, from: oldData)
        #expect(decoded.entries[0].succeeded == false)
        #expect(decoded.entries[0].errorDescription == nil)
    }

    @Test("two reports for the same app in the same second are both kept")
    func sameSecondReportsDoNotReplaceEachOther() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OperationReportStore(directory: root)
        let report = OperationReport(
            bundleIdentifier: "com.example.app",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: []
        )

        let first = try await store.save(report)
        let second = try await store.save(report)

        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("report encoding keeps the ISO 8601 format and optional values")
    func reportEncodingKeepsTheIsoFormatAndOptionalValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = OperationReport.Entry(path: "/tmp/日本", classification: "cache", requiresPrivilegedHelper: false, executed: true, succeeded: false, errorDescription: "失敗")
        let report = OperationReport(bundleIdentifier: "com.example.app", generatedAt: date, entries: [entry])
        let url = try await OperationReportStore(directory: root).save(report)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(OperationReport.self, from: data)
        #expect(decoded.generatedAt == date)
        #expect(decoded.entries.first?.path == entry.path)
        #expect(decoded.entries.first?.errorDescription == entry.errorDescription)
        #expect(String(decoding: data, as: UTF8.self).contains("\n"))
    }

    @Test("a hostile identifier cannot place the report outside its directory")
    func hostileIdentifierStaysInsideTheReportDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OperationReportStore(directory: root)
        let report = OperationReport(
            bundleIdentifier: "../../escaped",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: []
        )

        let url = try await store.save(report)

        #expect(url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    }

    @Test("save reports directory creation failures")
    func saveReportsDirectoryCreationFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)

        let store = OperationReportStore(directory: blocker)
        let report = OperationReport(
            bundleIdentifier: "com.example.app",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: []
        )
        var didFailWithDirectoryError = false
        do {
            _ = try await store.save(report)
        } catch OperationReportStoreError.directoryCreationFailed(_) {
            didFailWithDirectoryError = true
        } catch {
            #expect(Bool(false), "unexpected error: \(error)")
        }

        #expect(didFailWithDirectoryError)

        // Clearing the blocker must let the same instance recover without being recreated.
        try FileManager.default.removeItem(at: blocker)
        let url = try await store.save(report)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
