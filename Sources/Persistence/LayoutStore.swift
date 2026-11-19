import Diagnostics
import Foundation

import CLaunchpadCore
public enum LayoutStoreError: Error {
    case directoryCreationFailed(Error)
    case encodingFailed(Error)
    case backupFailed(Error)
    case writeFailed(Error)
}

private final class LayoutReadBuffer {
    var data = Data()
}

/// The layout document as JSON, through Foundation's coder. Keys are written in a fixed order,
/// so the same document always gives the same bytes: the backup and the "did anything change"
/// check in `GridModel` compare them.
public enum LayoutJSON {
    public static func encode(_ document: LayoutDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> LayoutDocument {
        try JSONDecoder().decode(LayoutDocument.self, from: data)
    }
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
            return doc
        case .failure(let error):
            if FileManager.default.fileExists(atPath: primaryURL.path) {
                DiagnosticsLog.persistence.error("layout.json exists but failed to decode: \(error.localizedDescription, privacy: .public); falling back to last-known-good backup")
            }
        }

        switch Self.decode(at: backupURL) {
        case .success(let backup):
            return backup
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
    public func save(_ document: LayoutDocument, updateBackup: Bool = true) throws {
        if let directoryCreationError {
            throw LayoutStoreError.directoryCreationFailed(directoryCreationError)
        }
        let data: Data
        do {
            data = try LayoutJSON.encode(document)
        } catch {
            throw LayoutStoreError.encodingFailed(error)
        }

        if FileManager.default.fileExists(atPath: primaryURL.path), case .failure = Self.decode(at: primaryURL) {
            quarantineUnreadablePrimary()
        } else if updateBackup && FileManager.default.fileExists(atPath: primaryURL.path) {
            do {
                let previous = try Self.readBytes(at: primaryURL)
                let result = backupURL.withUnsafeFileSystemRepresentation { path -> Int32 in
                    guard let path else { return 22 }
                    return previous.withUnsafeBytes { bytes in
                        launchpad_write_file_atomic(path, bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count))
                    }
                }
                guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
            } catch {
                DiagnosticsLog.persistence.error("Failed to prepare layout backup: \(error.localizedDescription, privacy: .public)")
                throw LayoutStoreError.backupFailed(error)
            }
        }

        let status = primaryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return 22 }
            return data.withUnsafeBytes { bytes in
                launchpad_write_file_atomic(path, bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count))
            }
        }
        guard status == 0 else {
            throw LayoutStoreError.writeFailed(NSError(domain: NSPOSIXErrorDomain, code: Int(status)))
        }
    }

    /// Moves a primary file that cannot be decoded out of the way, keeping it
    /// for inspection rather than deleting it.
    private func quarantineUnreadablePrimary() {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = primaryURL.deletingLastPathComponent()
            .appendingPathComponent("layout.unreadable-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        do {
            try FileManager.default.moveItem(at: primaryURL, to: destination)
            DiagnosticsLog.persistence.error("layout.json could not be decoded; set it aside instead of promoting it to the backup")
        } catch {
            DiagnosticsLog.persistence.error("Could not set the unreadable layout.json aside: \(error.localizedDescription, privacy: .public)")
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

    private static func readBytes(at url: URL) throws -> Data {
        let buffer = LayoutReadBuffer()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Void = { context, bytes, length in
            guard let context, let bytes, let count = Int(exactly: length) else { return }
            Unmanaged<LayoutReadBuffer>.fromOpaque(context).takeUnretainedValue().data = Data(bytes: bytes, count: count)
        }
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return 22 }
            return launchpad_read_file(path, Unmanaged.passUnretained(buffer).toOpaque(), callback)
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
        return buffer.data
    }

    private static func decode(at url: URL) -> Result<LayoutDocument, Error> {
        do {
            return .success(try LayoutJSON.decode(readBytes(at: url)))
        } catch {
            return .failure(error)
        }
    }

    public func readBackup(at url: URL) throws -> Data {
        let buffer = LayoutReadBuffer()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Void = { context, bytes, length in
            guard let context, let bytes, let count = Int(exactly: length) else { return }
            Unmanaged<LayoutReadBuffer>.fromOpaque(context).takeUnretainedValue().data = Data(bytes: bytes, count: count)
        }
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return 22 }
            return launchpad_read_file_limited(path, 8 * 1024 * 1024, Unmanaged.passUnretained(buffer).toOpaque(), callback)
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
        return buffer.data
    }

    public func writeBackup(_ data: Data, to url: URL) throws {
        guard data.count <= 8 * 1024 * 1024 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: 27)
        }
        let destination = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard destination != primaryURL.standardizedFileURL.resolvingSymlinksInPath().path,
              destination != backupURL.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw NSError(domain: NSPOSIXErrorDomain, code: 22)
        }
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return 22 }
            return data.withUnsafeBytes { bytes in
                launchpad_write_file_atomic(path, bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count))
            }
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
    }
}
