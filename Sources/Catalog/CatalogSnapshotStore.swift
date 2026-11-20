import Diagnostics
import Foundation

/// A small last-known-good catalog persisted between launches.
///
/// The snapshot is deliberately treated as a hint, not as the authoritative
/// catalog: records are pruned when their bundle path no longer exists or its
/// modification date no longer matches, and the live scanner reconciles it in
/// the background after the first frame.
import CLaunchpadCore

private final class RustOwnedBuffer: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer
    init(_ handle: UnsafeMutableRawPointer) { self.handle = handle }
    deinit { launchpad_read_owned_free(handle) }
}
public enum RustFileIO {
    public static func read(_ url: URL, limit: Int? = nil) -> Data? {
        if let limit, limit < 0 { return nil }
        var bytes: UnsafeMutablePointer<UInt8>?
        var length: UInt = 0
        let handle = url.withUnsafeFileSystemRepresentation { path -> UnsafeMutableRawPointer? in
            guard let path else { return nil }
            return launchpad_read_owned(path, limit.map(UInt.init) ?? UInt.max, &bytes, &length)
        }
        guard let handle else { return nil }
        guard let count = Int(exactly: length), let bytes else {
            launchpad_read_owned_free(handle)
            return nil
        }
        if count == 0 {
            launchpad_read_owned_free(handle)
            return Data()
        }
        let owner = RustOwnedBuffer(handle)
        return Data(bytesNoCopy: bytes, count: count, deallocator: .custom { _, _ in _ = owner })
    }

    static func write(_ data: Data, to url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return data.withUnsafeBytes { bytes in
                launchpad_write_cache_atomic(path, bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count)) == 0
            }
        }
    }
}
private enum SnapshotWireError: Error { case invalid }

private final class SnapshotBuffer { var data = Data() }

private final class SnapshotRecordsBuffer { var records: [ApplicationRecord]? }

private enum SnapshotWire {
    struct Reader {
        let data: UnsafeRawBufferPointer
        var offset = 0

        mutating func take(_ count: Int) throws -> UnsafeRawBufferPointer {
            guard count >= 0, offset <= data.count, count <= data.count - offset else { throw SnapshotWireError.invalid }
            defer { offset += count }
            return UnsafeRawBufferPointer(rebasing: data[offset..<(offset + count)])
        }

        mutating func u32() throws -> UInt32 {
            let bytes = try take(4)
            return UInt32(littleEndian: bytes.loadUnaligned(as: UInt32.self))
        }

        mutating func string(optional: Bool = false) throws -> String? {
            let count = try u32()
            if count == UInt32.max {
                guard optional else { throw SnapshotWireError.invalid }
                return nil
            }
            guard let value = String(bytes: try take(Int(count)), encoding: .utf8) else { throw SnapshotWireError.invalid }
            return value
        }

        mutating func required() throws -> String {
            guard let result = try string() else { throw SnapshotWireError.invalid }
            return result
        }

        mutating func flag() throws -> Bool {
            guard let value = try take(1).first, value <= 1 else { throw SnapshotWireError.invalid }
            return value == 1
        }

        mutating func date() throws -> Date {
            let bytes = try take(8)
            let bits = UInt64(littleEndian: bytes.loadUnaligned(as: UInt64.self))
            let value = Double(bitPattern: bits)
            guard value.isFinite else { throw SnapshotWireError.invalid }
            return Date(timeIntervalSinceReferenceDate: value)
        }
    }

    static func appendString(_ value: String?, to data: inout Data) throws {
        guard let value else {
            var marker = UInt32.max.littleEndian
            withUnsafeBytes(of: &marker) { data.append(contentsOf: $0) }
            return
        }
        let bytes = value.utf8
        guard let size = UInt32(exactly: bytes.count), size != UInt32.max else { throw SnapshotWireError.invalid }
        var sizeLE = size.littleEndian
        withUnsafeBytes(of: &sizeLE) { data.append(contentsOf: $0) }
        data.append(contentsOf: bytes)
    }

    static func pack(_ records: [ApplicationRecord]) throws -> Data {
        guard let count = UInt32(exactly: records.count) else { throw SnapshotWireError.invalid }
        var data = Data()
        var countLE = count.littleEndian
        withUnsafeBytes(of: &countLE) { data.append(contentsOf: $0) }
        for record in records {
            for value in [record.bundleIdentifier, record.bundleURL.absoluteString, record.displayName, record.originalDisplayName, record.sourceID, record.iconCacheKey, record.id.value] {
                try appendString(value, to: &data)
            }
            for value in [record.executableURL?.absoluteString, record.bundleVersion, record.teamIdentifier, record.category] {
                try appendString(value, to: &data)
            }
            data.append(contentsOf: [record.isSystemProtected, record.isBackgroundOnly, record.isMenuBarApp, record.canLaunch, record.canOpenNewInstance].map { $0 ? 1 : 0 })
            let date = record.lastSeenModificationDate.timeIntervalSinceReferenceDate
            guard date.isFinite else { throw SnapshotWireError.invalid }
            var bits = date.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func unpack(_ data: UnsafeRawBufferPointer) throws -> [ApplicationRecord] {
        var reader = Reader(data: data)
        let count = try reader.u32()
        guard Int(count) <= (data.count - reader.offset) / 57 else { throw SnapshotWireError.invalid }
        var records: [ApplicationRecord] = []
        records.reserveCapacity(Int(count))
        for _ in 0..<count {
            let bundleID = try reader.required()
            guard let bundleURL = URL(string: try reader.required()) else { throw SnapshotWireError.invalid }
            let displayName = try reader.required()
            let originalName = try reader.required()
            let sourceID = try reader.required()
            let iconKey = try reader.required()
            let stableID = try reader.required()
            let executableString = try reader.string(optional: true)
            let executableURL = executableString.flatMap(URL.init(string:))
            guard executableString == nil || executableURL != nil else { throw SnapshotWireError.invalid }
            let version = try reader.string(optional: true)
            let team = try reader.string(optional: true)
            let category = try reader.string(optional: true)
            let protected = try reader.flag()
            let background = try reader.flag()
            let menuBar = try reader.flag()
            let canLaunch = try reader.flag()
            let canOpenNewInstance = try reader.flag()
            let date = try reader.date()
            records.append(ApplicationRecord(id: StableAppID(snapshotValue: stableID), bundleIdentifier: bundleID, bundleURL: bundleURL, executableURL: executableURL, displayName: displayName, originalDisplayName: originalName, bundleVersion: version, teamIdentifier: team, category: category, sourceID: sourceID, isSystemProtected: protected, isBackgroundOnly: background, isMenuBarApp: menuBar, iconCacheKey: iconKey, canLaunch: canLaunch, canOpenNewInstance: canOpenNewInstance, lastSeenModificationDate: date))
        }
        guard reader.offset == data.count else { throw SnapshotWireError.invalid }
        return records
    }

    static func decodeRecords(_ data: Data) -> [ApplicationRecord]? {
        let output = SnapshotRecordsBuffer()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Void = { context, bytes, count in
            guard let context, let bytes, let count = Int(exactly: count) else { return }
            // Rust owns the buffer only for this callback; unpack copies each retained value.
            let wire = UnsafeRawBufferPointer(start: bytes, count: count)
            Unmanaged<SnapshotRecordsBuffer>.fromOpaque(context).takeUnretainedValue().records = try? SnapshotWire.unpack(wire)
        }
        let context = Unmanaged.passUnretained(output).toOpaque()
        let result = data.withUnsafeBytes { bytes in
            launchpad_catalog_decode(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count), context, callback)
        }
        return result == 1 ? output.records : nil
    }

    static func convert(_ data: Data) -> Data? {
        let output = SnapshotBuffer()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Void = { context, bytes, count in
            guard let context, let bytes, let count = Int(exactly: count) else { return }
            Unmanaged<SnapshotBuffer>.fromOpaque(context).takeUnretainedValue().data = Data(bytes: bytes, count: count)
        }
        let context = Unmanaged.passUnretained(output).toOpaque()
        // Rust serializes borrowed records without constructing a second object tree.
        let result = data.withUnsafeBytes { bytes in
            let pointer = bytes.bindMemory(to: UInt8.self).baseAddress
            return launchpad_catalog_encode(pointer, UInt(bytes.count), context, callback)
        }
        return result == 1 ? output.data : nil
    }
}
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
        let wire = try SnapshotWire.pack(boundedRecords(records, maximumRecords: maximumRecords))
        guard let result = SnapshotWire.convert(wire) else { throw SnapshotWireError.invalid }
        return result
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
              let records = SnapshotWire.decodeRecords(data) else { return nil }
        return boundedRecords(records, maximumRecords: maximumRecords)
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
        guard let data = RustFileIO.read(snapshotURL, limit: defaultMaximumBytes),
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

        guard data.count <= defaultMaximumBytes else { return }
        let directory = snapshotURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard RustFileIO.write(data, to: snapshotURL) else {
                DiagnosticsLog.catalog.error("Failed to write catalog snapshot")
                return
            }
        } catch {
            DiagnosticsLog.catalog.error("Failed to create catalog snapshot directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes records that cannot be trusted for the immediate frame. This
    /// only performs cheap filesystem metadata checks; code-signing identity
    /// is intentionally left to the later full scan.
    public static func prune(
        _ records: [ApplicationRecord],
        sources: [ApplicationSource]
    ) -> [ApplicationRecord] {
        // Duplicate source IDs must not trap; the first source with an ID wins.
        let sourceByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Resolve each source root once instead of once per record.
        // `resolvingSymlinksInPath()` issues a filesystem call per path
        // component, and there are only ever a handful of sources against
        // hundreds of records — this was the dominant cost of a path check
        // that runs on the launch path.
        let resolvedRootByID = sourceByID.mapValues {
            $0.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        }
        // A source whose root is not there at all — an unmounted volume — says
        // nothing about the apps it holds. Dropping them here meant the scanner
        // never saw them, so it had nothing to carry forward, and the next
        // authoritative update removed them from the user's pages and folders.
        let rootIsPresent = sourceByID.mapValues { source -> Bool in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: source.rootURL.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
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

                if rootIsPresent[record.sourceID] == false { return true }

                return record.bundleURL.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return false }
                    return launchpad_catalog_fresh(path, record.lastSeenModificationDate.timeIntervalSinceReferenceDate) != 0
                }
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
