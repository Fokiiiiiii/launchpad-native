import Diagnostics
import Foundation

public enum LayoutStoreError: Error {
    case encodingFailed(Error)
    case writeFailed(Error)
}

/// Reads/writes `LayoutDocument` with atomic writes and a last-known-good
/// backup, so a crash mid-write or a corrupted file never loses the previous
/// good state outright.
public actor LayoutStore {
    private let primaryURL: URL
    private let backupURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.launchpadnative.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.primaryURL = base.appendingPathComponent("layout.json")
        self.backupURL = base.appendingPathComponent("layout.lastknowngood.json")
    }

    /// Loads the current document, falling back to the last-known-good
    /// backup if the primary file is missing or fails to decode. Never
    /// throws — an unreadable store degrades to `.empty` rather than
    /// crashing the launcher.
    public func load() -> LayoutDocument {
        if let doc = Self.decode(at: primaryURL) {
            return LayoutSchemaMigrator.migrate(doc)
        }
        if FileManager.default.fileExists(atPath: primaryURL.path) {
            DiagnosticsLog.persistence.error("layout.json exists but failed to decode; falling back to last-known-good backup")
        }
        if let backup = Self.decode(at: backupURL) {
            return LayoutSchemaMigrator.migrate(backup)
        }
        return .empty
    }

    /// Atomic write: the previous primary is promoted to the backup slot
    /// before the new one lands, so a write that fails partway never leaves
    /// the store worse off than before.
    public func save(_ document: LayoutDocument) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(document)
        } catch {
            throw LayoutStoreError.encodingFailed(error)
        }

        if FileManager.default.fileExists(atPath: primaryURL.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: primaryURL, to: backupURL)
        }

        let tempURL = primaryURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(primaryURL, withItemAt: tempURL)
        } catch {
            throw LayoutStoreError.writeFailed(error)
        }
    }

    private static func decode(at url: URL) -> LayoutDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LayoutDocument.self, from: data)
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
