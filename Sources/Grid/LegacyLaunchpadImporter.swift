import Catalog
import Foundation
import Persistence
import SQLite3

/// Read-only importer for the pre-macOS-26 Classic Launchpad SQLite DB
/// (`ReverseEngineering/Contracts/open-items.md`: confirmed present and
/// non-empty on this machine, schema matches exactly). Never writes to
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
public struct LegacyImportResult: Sendable {
    public var folders: [Folder]
    public var unplacedAppOrder: [LayoutItem]
    public var unresolvedBundleIDs: [String]
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
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return LegacyImportResult(folders: [], unplacedAppOrder: [], unresolvedBundleIDs: [])
        }
        defer { sqlite3_close(db) }

        struct ItemRow { var rowid: Int64; var uuid: String }

        var uuidByRowID: [Int64: String] = [:]
        var childrenByParent: [Int64: [(rowid: Int64, ordering: Int)]] = [:]

        queryRows(db, "SELECT rowid, uuid, parent_id, ordering FROM items") { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            let uuid = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let parentID = sqlite3_column_int64(stmt, 2)
            let ordering = Int(sqlite3_column_int(stmt, 3))
            uuidByRowID[rowid] = uuid
            childrenByParent[parentID, default: []].append((rowid, ordering))
        }

        var bundleIDByItem: [Int64: String] = [:]
        queryRows(db, "SELECT item_id, bundleid FROM apps") { stmt in
            let itemID = sqlite3_column_int64(stmt, 0)
            if let cstr = sqlite3_column_text(stmt, 1) {
                bundleIDByItem[itemID] = String(cString: cstr)
            }
        }

        var folderTitleByItem: [Int64: String] = [:]
        queryRows(db, "SELECT item_id, title FROM groups") { stmt in
            let itemID = sqlite3_column_int64(stmt, 0)
            if let cstr = sqlite3_column_text(stmt, 1) {
                folderTitleByItem[itemID] = String(cString: cstr)
            }
        }

        let recordsByBundleID = Dictionary(grouping: records, by: \.bundleIdentifier)
        func resolveIdentifier(bundleID: String) -> StableAppIdentifier? {
            recordsByBundleID[bundleID]?.first?.id.asPersistenceIdentifier
        }

        func sortedChildren(of parentID: Int64) -> [Int64] {
            (childrenByParent[parentID] ?? []).sorted { $0.ordering < $1.ordering }.map(\.rowid)
        }

        func collectAppBundleIDs(under parentID: Int64) -> [String] {
            sortedChildren(of: parentID).flatMap { child -> [String] in
                if let bundleID = bundleIDByItem[child] {
                    return [bundleID]
                }
                return collectAppBundleIDs(under: child)
            }
        }

        var unresolvedBundleIDs: Set<String> = []
        var folders: [Folder] = []
        var unplacedItems: [LayoutItem] = []

        func resolveOrMarkUnresolved(_ bundleID: String) -> LayoutItem? {
            guard let identifier = resolveIdentifier(bundleID: bundleID) else {
                unresolvedBundleIDs.insert(bundleID)
                return nil
            }
            return .app(identifier)
        }

        func walk(parentID: Int64) {
            for child in sortedChildren(of: parentID) {
                if let bundleID = bundleIDByItem[child] {
                    if let item = resolveOrMarkUnresolved(bundleID) {
                        unplacedItems.append(item)
                    }
                } else if let folderName = folderTitleByItem[child] {
                    let folderItems = collectAppBundleIDs(under: child).compactMap(resolveOrMarkUnresolved)
                    if !folderItems.isEmpty {
                        let folder = Folder(name: folderName, pages: [folderItems])
                        folders.append(folder)
                        // Kept interleaved with app items (not appended
                        // separately at the end) so the folder's position
                        // relative to top-level apps matches the legacy
                        // ordering.
                        unplacedItems.append(.folder(folder.id))
                    }
                } else {
                    walk(parentID: child)
                }
            }
        }

        guard let root = uuidByRowID.first(where: { $0.value == "ROOTPAGE" })?.key else {
            return LegacyImportResult(folders: [], unplacedAppOrder: [], unresolvedBundleIDs: [])
        }
        walk(parentID: root)

        return LegacyImportResult(
            folders: folders,
            unplacedAppOrder: unplacedItems,
            unresolvedBundleIDs: unresolvedBundleIDs.sorted()
        )
    }

    private static func queryRows(_ db: OpaquePointer, _ sql: String, _ handler: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            handler(stmt)
        }
    }
}
