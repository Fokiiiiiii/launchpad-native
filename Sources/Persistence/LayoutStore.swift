import Diagnostics
import Foundation

public enum LayoutStoreError: Error {
    case directoryCreationFailed(Error)
    case encodingFailed(Error)
    case backupFailed(Error)
    case writeFailed(Error)
}

/// Reads/writes `LayoutDocument` with atomic writes and a last-known-good
/// backup, so a crash mid-write or a corrupted file never loses the previous
/// good state outright.
public actor LayoutStore {
    private let primaryURL: URL
    private let backupURL: URL
    private let directoryCreationError: Error?

    public init(directory: URL? = nil) {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let base = directory ?? applicationSupport
            .appendingPathComponent("com.launchpadnative.app", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.directoryCreationError = nil
        } catch {
            DiagnosticsLog.persistence.error("Failed to create layout directory: \(error.localizedDescription, privacy: .public)")
            self.directoryCreationError = error
        }
        self.primaryURL = base.appendingPathComponent("layout.json")
        self.backupURL = base.appendingPathComponent("layout.lastknowngood.json")
    }

    /// Loads the current document, falling back to the last-known-good
    /// backup if the primary file is missing or fails to decode. Never
    /// throws — an unreadable store degrades to `.empty` rather than
    /// crashing the launcher.
    public func load() -> LayoutDocument {
        switch Self.decode(at: primaryURL) {
        case .success(let doc):
            return LayoutSchemaMigrator.migrate(doc)
        case .failure(let error):
            if FileManager.default.fileExists(atPath: primaryURL.path) {
                DiagnosticsLog.persistence.error("layout.json exists but failed to decode: \(error.localizedDescription, privacy: .public); falling back to last-known-good backup")
            }
        }

        switch Self.decode(at: backupURL) {
        case .success(let backup):
            return LayoutSchemaMigrator.migrate(backup)
        case .failure(let error):
            if FileManager.default.fileExists(atPath: backupURL.path) {
                DiagnosticsLog.persistence.error("layout.lastknowngood.json exists but failed to decode: \(error.localizedDescription, privacy: .public); returning empty layout")
            }
        }
        return .empty
    }

    /// Atomic write: the previous primary is promoted to the backup slot
    /// before the new one lands, so a write that fails partway never leaves
    /// the store worse off than before.
    public func save(_ document: LayoutDocument) throws {
        if let directoryCreationError {
            throw LayoutStoreError.directoryCreationFailed(directoryCreationError)
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(document)
        } catch {
            throw LayoutStoreError.encodingFailed(error)
        }

        if FileManager.default.fileExists(atPath: primaryURL.path) {
            let temporaryBackupURL = backupURL.appendingPathExtension("tmp")
            do {
                if FileManager.default.fileExists(atPath: temporaryBackupURL.path) {
                    try FileManager.default.removeItem(at: temporaryBackupURL)
                }
                try FileManager.default.copyItem(at: primaryURL, to: temporaryBackupURL)
                if FileManager.default.fileExists(atPath: backupURL.path) {
                    _ = try FileManager.default.replaceItemAt(backupURL, withItemAt: temporaryBackupURL)
                } else {
                    try FileManager.default.moveItem(at: temporaryBackupURL, to: backupURL)
                }
            } catch {
                DiagnosticsLog.persistence.error("Failed to prepare layout backup: \(error.localizedDescription, privacy: .public)")
                throw LayoutStoreError.backupFailed(error)
            }
        }

        let tempURL = primaryURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(primaryURL, withItemAt: tempURL)
        } catch {
            throw LayoutStoreError.writeFailed(error)
        }
    }

    /// Synchronous-result wrapper for runtime transactions that must know
    /// whether a restore point was durably written before applying an
    /// external side effect. Existing callers that use the throwing API keep
    /// their current behavior.
    public func saveResult(_ document: LayoutDocument) -> Bool {
        do {
            try save(document)
            return true
        } catch {
            DiagnosticsLog.persistence.error("Failed to save layout: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static func decode(at url: URL) -> Result<LayoutDocument, Error> {
        do {
            let data = try Data(contentsOf: url)
            return .success(try JSONDecoder().decode(LayoutDocument.self, from: data))
        } catch {
            return .failure(error)
        }
    }
}

/// Placeholder migration chain. Only schema version 1 exists today; this
/// exists so adding version 2 later is a new `case` here, not a rewrite of
/// `LayoutStore`.
enum LayoutSchemaMigrator {
    static func migrate(_ document: LayoutDocument) -> LayoutDocument {
        var document = document
        if document.schemaVersion < LayoutDocument.currentSchemaVersion {
            document.schemaVersion = LayoutDocument.currentSchemaVersion
        }
        return document
    }
}
