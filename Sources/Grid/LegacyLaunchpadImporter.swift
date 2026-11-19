import Catalog
import Foundation
import Persistence
import SQLite3

/// Read-only importer for the pre-macOS-26 Classic Launchpad SQLite DB
/// (confirmed present and non-empty on this machine, schema matches
/// exactly). Never writes to
/// Apple's storage — only reads.
///
/// Fidelity note: this reconstructs folder membership/names and app
/// ordering faithfully (matched by bundle identifier), but does **not**
/// reproduce the exact original page *boundaries* — the legacy schema's
/// intermediate "holding page" containers are walked through rather than
/// mapped 1:1 to specific page indices. That's a deliberate, disclosed
/// simplification: the spec's own success criteria (2.6) are page order,
/// folder position/name/contents, and app order, which this preserves;
/// exact page-break placement was not called out as required and doing it
/// precisely would need reverse-engineering undocumented "holding page"
/// semantics with no behavioral payoff.
import CLaunchpadCore

private final class LegacyImportBuffer {
    var records: [String: StableAppIdentifier] = [:]
    var unresolved: Set<String> = []
    var folders: [Folder] = []
    var order: [LayoutItem] = []
    var folderName: String?
    var folderItems: [LayoutItem] = []
    var valid = true

    func accept(_ kind: Int32, _ bytes: UnsafePointer<UInt8>?, _ count: UInt) {
        guard let length = Int(exactly: count), length == 0 || bytes != nil else { valid = false; return }
        let value = String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
        switch kind {
        case 0, 2:
            guard (kind == 2) == (folderName != nil) else { valid = false; return }
            if let identifier = records[value] {
                if kind == 2 { folderItems.append(.app(identifier)) } else { order.append(.app(identifier)) }
            } else { unresolved.insert(value) }
        case 1:
            guard folderName == nil else { valid = false; return }
            folderName = value
            folderItems.removeAll(keepingCapacity: true)
        case 3:
            guard let name = folderName else { valid = false; return }
            if !folderItems.isEmpty {
                let folder = Folder(name: name, pages: [folderItems])
                folders.append(folder)
                order.append(.folder(folder.id))
            }
            folderName = nil
        default:
            valid = false
        }
    }
}

public struct LegacyImportResult: Sendable {
    public var folders: [Folder]
    public var unplacedAppOrder: [LayoutItem]
    public var unresolvedBundleIDs: [String]
    public var succeeded: Bool = true
}

public enum LegacyLaunchpadImporter {
    public static func defaultDatabaseURL() -> URL? {
        let bufSize = confstr(_CS_DARWIN_USER_DIR, nil, 0)
        guard bufSize > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: bufSize)
        buffer.withUnsafeMutableBufferPointer { ptr in
            _ = ptr.baseAddress?.withMemoryRebound(to: CChar.self, capacity: bufSize) {
                confstr(_CS_DARWIN_USER_DIR, $0, bufSize)
            }
        }
        let darwinDir = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        let path = darwinDir + "com.apple.dock.launchpad/db/db"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    public static func importLegacyLayout(from url: URL, matching records: [ApplicationRecord]) -> LegacyImportResult {
        let buffer = LegacyImportBuffer()
        for record in records where buffer.records[record.bundleIdentifier] == nil {
            buffer.records[record.bundleIdentifier] = record.id.asPersistenceIdentifier
        }
        let callback: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<UInt8>?, UInt) -> Void = { context, kind, bytes, count in
            guard let context else { return }
            Unmanaged<LegacyImportBuffer>.fromOpaque(context).takeUnretainedValue().accept(kind, bytes, count)
        }
        let status = url.withUnsafeFileSystemRepresentation { path in
            launchpad_import_legacy(path, Unmanaged.passUnretained(buffer).toOpaque(), callback)
        }
        guard status == 1, buffer.valid, buffer.folderName == nil else {
            return LegacyImportResult(folders: [], unplacedAppOrder: [], unresolvedBundleIDs: [], succeeded: false)
        }
        return LegacyImportResult(folders: buffer.folders, unplacedAppOrder: buffer.order, unresolvedBundleIDs: buffer.unresolved.sorted())
    }

}
