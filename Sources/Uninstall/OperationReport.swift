import Diagnostics
import Foundation

/// A snapshot of one removal plan or execution.
/// Dry-run entries have `executed == false` and no result yet; execution
/// entries carry the outcome and any failure reason returned by the executor.
public struct OperationReport: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let path: String
        public let classification: String
        public let requiresPrivilegedHelper: Bool
        public let executed: Bool
        public let succeeded: Bool?
        public let errorDescription: String?

        public init(
            path: String,
            classification: String,
            requiresPrivilegedHelper: Bool,
            executed: Bool = false,
            succeeded: Bool? = nil,
            errorDescription: String? = nil
        ) {
            self.path = path
            self.classification = classification
            self.requiresPrivilegedHelper = requiresPrivilegedHelper
            self.executed = executed
            self.succeeded = succeeded
            self.errorDescription = errorDescription
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
    case directoryCreationFailed(Error)
    case encodingFailed(Error)
    case writeFailed(Error)
}

public extension OperationReport {
    /// Builds a dry-run report from a plan — every entry's `executed` stays
    /// `false` because this initializer records the plan without acting on it.
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
    /// entry's `executed` is `true`, with `succeeded` and `errorDescription`
    /// reflecting what actually happened (including refused items, which
    /// remain in the report with their explanatory reason).
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
                    succeeded: $0.succeeded,
                    errorDescription: $0.errorDescription
                )
            }
        )
    }
}

/// Persists `OperationReport`s with atomic writes. One file per
/// (bundle identifier, timestamp) rather than one shared file, since
/// reports are an append-only history, not a single mutable document.
public actor OperationReportStore {
    private let directory: URL
    private let directoryCreationError: Error?

    public init(directory: URL? = nil) {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let base = directory ?? applicationSupport
            .appendingPathComponent("com.launchpadnative.app", isDirectory: true)
            .appendingPathComponent("uninstall-reports", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.directoryCreationError = nil
        } catch {
            DiagnosticsLog.uninstall.error("Failed to create operation report directory: \(error.localizedDescription, privacy: .public)")
            self.directoryCreationError = error
        }
        self.directory = base
    }

    @discardableResult
    public func save(_ report: OperationReport) throws -> URL {
        if let directoryCreationError {
            throw OperationReportStoreError.directoryCreationFailed(directoryCreationError)
        }

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
