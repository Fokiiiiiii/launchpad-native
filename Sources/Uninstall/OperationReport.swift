import Diagnostics
import Foundation

/// A snapshot of one removal plan, recorded before anything is executed.
/// This phase never executes removals, so every report is a dry run — the
/// `executed`/`succeeded` fields exist now so a later phase that adds real
/// execution doesn't need a schema change, just to start setting them.
public struct OperationReport: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let path: String
        public let classification: String
        public let requiresPrivilegedHelper: Bool
        public let executed: Bool
        public let succeeded: Bool?

        public init(path: String, classification: String, requiresPrivilegedHelper: Bool, executed: Bool = false, succeeded: Bool? = nil) {
            self.path = path
            self.classification = classification
            self.requiresPrivilegedHelper = requiresPrivilegedHelper
            self.executed = executed
            self.succeeded = succeeded
        }
    }

    public let bundleIdentifier: String
    public let generatedAt: Date
    public let entries: [Entry]

    public init(bundleIdentifier: String, generatedAt: Date, entries: [Entry]) {
        self.bundleIdentifier = bundleIdentifier
        self.generatedAt = generatedAt
        self.entries = entries
    }
}

public enum OperationReportStoreError: Error {
    case encodingFailed(Error)
    case writeFailed(Error)
}

public extension OperationReport {
    /// Builds a dry-run report from a plan — every entry's `executed` stays
    /// `false` since this phase never acts on a plan, only records it.
    init(bundleIdentifier: String, generatedAt: Date, plan: [RemovalItem]) {
        self.init(
            bundleIdentifier: bundleIdentifier,
            generatedAt: generatedAt,
            entries: plan.map {
                Entry(
                    path: $0.path.path,
                    classification: String(describing: $0.classification),
                    requiresPrivilegedHelper: $0.requiresPrivilegedHelper
                )
            }
        )
    }

    /// Builds a report from real `RemovalExecutor.execute` results — every
    /// entry's `executed` is `true`, with `succeeded`/an error reason
    /// reflecting what actually happened (including the refused
    /// sharedRisk/unknown/privileged-helper items, whose `succeeded` is
    /// `false` with an explanatory reason, never silently dropped).
    init(bundleIdentifier: String, generatedAt: Date, outcomes: [RemovalOutcome]) {
        self.init(
            bundleIdentifier: bundleIdentifier,
            generatedAt: generatedAt,
            entries: outcomes.map {
                Entry(
                    path: $0.item.path.path,
                    classification: String(describing: $0.item.classification),
                    requiresPrivilegedHelper: $0.item.requiresPrivilegedHelper,
                    executed: true,
                    succeeded: $0.succeeded
                )
            }
        )
    }
}

/// Persists `OperationReport`s with the same atomic-write-plus-backup
/// durability as `Persistence.LayoutStore`: a report that fails to write
/// partway never corrupts a previously-saved one. One file per
/// (bundle identifier, timestamp) rather than one shared file, since
/// reports are an append-only history, not a single mutable document.
public actor OperationReportStore {
    private let directory: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.launchpadnative.app", isDirectory: true)
            .appendingPathComponent("uninstall-reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
    }

    @discardableResult
    public func save(_ report: OperationReport) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(report)
        } catch {
            throw OperationReportStoreError.encodingFailed(error)
        }

        // Each report is a new, uniquely-named file (bundle ID + timestamp),
        // never overwritten — so a plain atomic write is enough; there's no
        // previous version at this exact path to preserve as a backup.
        let timestamp = Int(report.generatedAt.timeIntervalSince1970)
        let url = directory.appendingPathComponent("\(report.bundleIdentifier)-\(timestamp).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            DiagnosticsLog.uninstall.error("Failed to write operation report: \(error.localizedDescription, privacy: .public)")
            throw OperationReportStoreError.writeFailed(error)
        }
        return url
    }

    /// Convenience for the execution path: builds the report from outcomes
    /// and saves it in one call, mirroring `save(_:)`'s dry-run counterpart.
    @discardableResult
    public func recordExecution(bundleIdentifier: String, outcomes: [RemovalOutcome]) throws -> URL {
        try save(OperationReport(bundleIdentifier: bundleIdentifier, generatedAt: Date(), outcomes: outcomes))
    }
}
