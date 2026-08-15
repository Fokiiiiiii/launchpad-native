import Diagnostics
import Foundation

/// A small last-known-good catalog persisted between launches.
///
/// The snapshot is deliberately treated as a hint, not as the authoritative
/// catalog: records are pruned when their bundle path no longer exists or its
/// modification date no longer matches, and the live scanner reconciles it in
/// the background after the first frame.
public enum CatalogSnapshotStore {
    public static let currentVersion = 1
    public static let defaultMaximumRecords = 4_096
    public static let defaultMaximumBytes = 8 * 1024 * 1024

    public struct Snapshot: Codable, Sendable {
        public let version: Int
        public let records: [ApplicationRecord]

        public init(version: Int = CatalogSnapshotStore.currentVersion, records: [ApplicationRecord]) {
            self.version = version
            self.records = records
        }
    }

    /// Encodes a bounded, deterministic snapshot for tests and atomic writes.
    public static func encode(
        records: [ApplicationRecord],
        maximumRecords: Int = defaultMaximumRecords
    ) throws -> Data {
        let bounded = boundedRecords(records, maximumRecords: maximumRecords)
        return try JSONEncoder().encode(Snapshot(records: bounded))
    }

    /// Decodes a snapshot without touching the filesystem or calling any
    /// per-bundle Security API. A malformed/unknown-version snapshot is
    /// rejected so the next full scan remains the source of truth.
    public static func decode(
        _ data: Data,
        maximumRecords: Int = defaultMaximumRecords,
        maximumBytes: Int = defaultMaximumBytes
    ) -> [ApplicationRecord]? {
        guard data.count <= maximumBytes,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == currentVersion
        else {
            return nil
        }
        return boundedRecords(snapshot.records, maximumRecords: maximumRecords)
    }

    /// Loads and prunes the last-known-good file. The file itself is never
    /// rewritten on a read; stale records simply disappear from this launch's
    /// fast path and are removed when the background full scan is saved.
    public static func load(
        sources: [ApplicationSource],
        url: URL? = nil,
        maximumRecords: Int = defaultMaximumRecords
    ) -> [ApplicationRecord] {
        let snapshotURL = url ?? defaultURL
        guard let data = try? Data(contentsOf: snapshotURL),
              let records = decode(data, maximumRecords: maximumRecords)
        else {
            return []
        }

        let valid = prune(records, sources: sources)
        DiagnosticsLog.catalog.info(
            "Catalog snapshot restored: \(valid.count, privacy: .public) records"
        )
        return valid
    }

    /// Saves a bounded snapshot atomically. A failed write leaves the previous
    /// last-known-good file untouched.
    public static func save(
        records: [ApplicationRecord],
        sources: [ApplicationSource],
        url: URL? = nil,
        maximumRecords: Int = defaultMaximumRecords
    ) {
        let snapshotURL = url ?? defaultURL
        let valid = prune(records, sources: sources)
        guard let data = try? encode(records: valid, maximumRecords: maximumRecords) else {
            return
        }

        let fm = FileManager.default
        let directory = snapshotURL.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(
            ".\(snapshotURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporaryURL, options: .atomic)
            if fm.fileExists(atPath: snapshotURL.path) {
                _ = try fm.replaceItemAt(snapshotURL, withItemAt: temporaryURL)
            } else {
                try fm.moveItem(at: temporaryURL, to: snapshotURL)
            }
        } catch {
            try? fm.removeItem(at: temporaryURL)
        }
    }

    /// Removes records that cannot be trusted for the immediate frame. This
    /// only performs cheap filesystem metadata checks; code-signing identity
    /// is intentionally left to the later full scan.
    public static func prune(
        _ records: [ApplicationRecord],
        sources: [ApplicationSource]
    ) -> [ApplicationRecord] {
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        // Resolve each source root once instead of once per record.
        // `resolvingSymlinksInPath()` issues a filesystem call per path
        // component, and there are only ever a handful of sources against
        // hundreds of records — this was the dominant cost of a path check
        // that runs on the launch path.
        let resolvedRootByID = sourceByID.mapValues {
            $0.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        }
        return records
            .filter { record in
                guard let source = sourceByID[record.sourceID],
                      let resolvedRoot = resolvedRootByID[record.sourceID],
                      record.bundleURL.pathExtension == "app",
                      isPath(record.bundleURL, insideResolvedRoot: resolvedRoot),
                      source.matches(bundleFilename: record.bundleURL.lastPathComponent)
                else {
                    return false
                }

                // Deliberately `fileExists` and not a `resourceValues` lookup
                // for existence: `URL` caches resource values, so a bundle
                // deleted after the snapshot was taken can still answer from
                // that cache and survive pruning. `CatalogSnapshotStoreTests`
                // covers exactly this case.
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: record.bundleURL.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    return false
                }

                guard let modificationDate = (try? record.bundleURL.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate else {
                    return false
                }

                // HFS/APFS metadata can be rounded by a small amount when
                // serialized through JSON. A sub-second tolerance avoids
                // throwing away a perfectly usable snapshot while still
                // rejecting a bundle changed since it was scanned.
                return abs(
                    modificationDate.timeIntervalSinceReferenceDate
                        - record.lastSeenModificationDate.timeIntervalSinceReferenceDate
                ) < 1.0
            }
            .sorted {
                if $0.displayName != $1.displayName {
                    return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                return $0.id.value < $1.id.value
            }
    }

    public static var defaultURL: URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("com.launchpadnative.app", isDirectory: true)
            .appendingPathComponent("catalog.snapshot.json")
    }

    private static func boundedRecords(
        _ records: [ApplicationRecord],
        maximumRecords: Int
    ) -> [ApplicationRecord] {
        guard maximumRecords > 0, records.count > maximumRecords else {
            return records
        }
        return Array(records.sorted { $0.id.value < $1.id.value }.prefix(maximumRecords))
    }

    /// - Parameter resolvedRoot: an already symlink-resolved root path, hoisted
    ///   out of the per-record loop by the caller.
    private static func isPath(_ bundleURL: URL, insideResolvedRoot root: String) -> Bool {
        let path = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        if path == root { return true }
        return root == "/" ? path.hasPrefix("/") : path.hasPrefix(root + "/")
    }
}
