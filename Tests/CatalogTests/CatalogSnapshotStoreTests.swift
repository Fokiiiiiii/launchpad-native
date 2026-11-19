import Foundation
import Testing
@testable import Catalog

import Darwin

private func makeSnapshotFixture(in root: URL, name: String = "Fixture.app") throws -> (ApplicationRecord, ApplicationSource) {
    let bundleURL = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    let modificationDate = (try FileManager.default.attributesOfItem(atPath: bundleURL.path)[.modificationDate] as? Date) ?? Date()
    let bundleID = "com.example.\(name.replacingOccurrences(of: ".app", with: "").lowercased())"
    let record = ApplicationRecord(
        id: StableAppID(bundleURL: bundleURL, bundleIdentifier: bundleID, teamIdentifier: nil),
        bundleIdentifier: bundleID,
        bundleURL: bundleURL,
        executableURL: nil,
        displayName: name,
        originalDisplayName: name,
        bundleVersion: nil,
        teamIdentifier: nil,
        category: nil,
        sourceID: "fixture",
        isSystemProtected: false,
        isBackgroundOnly: false,
        isMenuBarApp: false,
        iconCacheKey: bundleID,
        canLaunch: false,
        canOpenNewInstance: true,
        lastSeenModificationDate: modificationDate
    )
    let source = ApplicationSource(id: "fixture", rootURL: root, recursive: true, priority: 0)
    return (record, source)
}

@Test func catalogSnapshotRoundTripsRecords() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let (record, _) = try makeSnapshotFixture(in: root)
    let data = try CatalogSnapshotStore.encode(records: [record])
    let decoded = try #require(CatalogSnapshotStore.decode(data))
    #expect(decoded == [record])
}

@Test func rustSnapshotJSONIsCompatibleWithSwiftCodable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (original, _) = try makeSnapshotFixture(in: root, name: "日本 語.app")
    var rich = original
    rich.displayName = "家族 👨‍👩‍👧 \u{0} \""
    rich.executableURL = original.bundleURL.appendingPathComponent("Contents/MacOS/実行")
    rich.bundleVersion = "1.2.3"
    rich.teamIdentifier = "EXAMPLE"
    rich.category = "utility"
    rich.isSystemProtected = true
    rich.isMenuBarApp = true
    rich.lastSeenModificationDate = Date(timeIntervalSinceReferenceDate: -123.25)
    let records = [original, rich]
    let legacy = try JSONEncoder().encode(CatalogSnapshotStore.Snapshot(records: records))
    let decodedLegacy = try #require(CatalogSnapshotStore.decode(legacy))
    for _ in 0..<20 { _ = CatalogSnapshotStore.decode(legacy) }
    #expect(decodedLegacy == records)
    let rust = try CatalogSnapshotStore.encode(records: records)
    let decoded = try JSONDecoder().decode(CatalogSnapshotStore.Snapshot.self, from: rust)
    #expect(decoded.records == records)
    #expect(CatalogSnapshotStore.decode(Data("{\"version\":1,\"records\":[{}]}".utf8)) == nil)
    #expect(CatalogSnapshotStore.decode(Data("{\"version\":1.0,\"records\":[]}".utf8)) == [])
    #expect(CatalogSnapshotStore.decode(Data("{\"version\":2,\"records\":[]}".utf8)) == nil)
}

@Test func benchmarkSnapshotJSON() throws {
    guard ProcessInfo.processInfo.environment["LAUNCHPAD_BENCHMARK"] == "1" else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (fixture, _) = try makeSnapshotFixture(in: root)
    let records: [ApplicationRecord] = (0..<1000).map { index in
        var value = fixture
        value.id = StableAppID(snapshotValue: "id-\(index)")
        value.displayName = "アプリ \(index)"
        return value
    }
    let snapshot = CatalogSnapshotStore.Snapshot(records: records)
    var swiftData = Data()
    let swiftStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<10 { swiftData = try JSONEncoder().encode(snapshot) }
    let swiftEncode = DispatchTime.now().uptimeNanoseconds - swiftStart
    var rustData = Data()
    let rustStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<10 { rustData = try CatalogSnapshotStore.encode(records: records) }
    let rustEncode = DispatchTime.now().uptimeNanoseconds - rustStart
    let swiftDecodeStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<10 { #expect(try JSONDecoder().decode(CatalogSnapshotStore.Snapshot.self, from: swiftData).records.count == records.count) }
    let swiftDecode = DispatchTime.now().uptimeNanoseconds - swiftDecodeStart
    let rustDecodeStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<10 { #expect(CatalogSnapshotStore.decode(rustData)?.count == records.count) }
    let rustDecode = DispatchTime.now().uptimeNanoseconds - rustDecodeStart
    print("SNAPSHOT_BENCH records=1000 rounds=10 swift_encode_ns=\(swiftEncode) rust_encode_ns=\(rustEncode) swift_decode_ns=\(swiftDecode) rust_decode_ns=\(rustDecode)")
}

@Test func benchmarkCatalogMemory() throws {
    guard ProcessInfo.processInfo.environment["LAUNCHPAD_BENCHMARK"] == "1",
          let mode = ProcessInfo.processInfo.environment["LAUNCHPAD_MEMORY_MODE"] else { return }
    let count = Int(ProcessInfo.processInfo.environment["LAUNCHPAD_MEMORY_ITEMS"] ?? "1000") ?? 1000
    guard (1...10_000).contains(count) else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (fixture, _) = try makeSnapshotFixture(in: root)
    let records: [ApplicationRecord] = (0..<count).map { index in
        var value = fixture
        value.id = StableAppID(snapshotValue: "id-\(index)")
        value.displayName = "アプリ \(index)"
        return value
    }
    let snapshot = CatalogSnapshotStore.Snapshot(records: records)
    let input = mode.hasPrefix("decode") ? try JSONEncoder().encode(snapshot) : Data()
    func peak() -> Int {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        return usage.ru_maxrss
    }
    let baseline = peak()
    var checksum = 0
    for _ in 0..<5 {
        switch mode {
        case "encode-swift": checksum += try JSONEncoder().encode(snapshot).count
        case "encode-rust": checksum += try CatalogSnapshotStore.encode(records: records, maximumRecords: count).count
        case "decode-swift": checksum += try JSONDecoder().decode(CatalogSnapshotStore.Snapshot.self, from: input).records.count
        case "decode-rust": checksum += CatalogSnapshotStore.decode(input, maximumRecords: count)?.count ?? 0
        default: return
        }
    }
    #expect(checksum > 0)
    print("MEMORY_BENCH scenario=catalog mode=\(mode) items=\(count) baseline_bytes=\(baseline) peak_bytes=\(peak())")
}

@Test func rustFileIOHonorsLimitsAndKeepsExistingFileOnFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("data")
    let bytes = Data([0, 255, 1, 2])
    #expect(RustFileIO.write(bytes, to: url))
    #expect(RustFileIO.read(url, limit: 3) == nil)
    #expect(RustFileIO.read(url, limit: 4) == bytes)
    #expect(!RustFileIO.write(bytes, to: root.appendingPathComponent("missing/data")))
    var first = try #require(RustFileIO.read(url))
    let second = first
    first[0] = 7
    #expect(second == bytes)
    #expect(RustFileIO.read(url) == bytes)
    #expect(RustFileIO.write(Data(), to: url))
    #expect(RustFileIO.read(url) == Data())
    #expect(RustFileIO.read(url, limit: -1) == nil)
}

@Test func benchmarkFileIO() throws {
    guard ProcessInfo.processInfo.environment["LAUNCHPAD_BENCHMARK"] == "1" else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let swiftURL = root.appendingPathComponent("swift")
    let rustURL = root.appendingPathComponent("rust")
    let bytes = Data(repeating: 0x5a, count: 256 * 1024)
    try bytes.write(to: swiftURL, options: .atomic)
    #expect(RustFileIO.write(bytes, to: rustURL))
    let startSwiftRead = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<30 { #expect((try Data(contentsOf: swiftURL)).count == bytes.count) }
    let swiftRead = DispatchTime.now().uptimeNanoseconds - startSwiftRead
    let startRustRead = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<30 { #expect(RustFileIO.read(rustURL)?.count == bytes.count) }
    let rustRead = DispatchTime.now().uptimeNanoseconds - startRustRead
    let startSwiftWrite = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<8 { try bytes.write(to: swiftURL, options: .atomic) }
    let swiftWrite = DispatchTime.now().uptimeNanoseconds - startSwiftWrite
    let startRustWrite = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<8 { #expect(RustFileIO.write(bytes, to: rustURL)) }
    let rustWrite = DispatchTime.now().uptimeNanoseconds - startRustWrite
    #expect(RustFileIO.read(rustURL) == bytes)
    print("IO_BENCH bytes=262144 reads=30 writes=8 swift_read_ns=\(swiftRead) rust_read_ns=\(rustRead) swift_write_ns=\(swiftWrite) rust_write_ns=\(rustWrite)")
}

@Test func catalogSnapshotPrunesDeletedBundles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let (record, source) = try makeSnapshotFixture(in: root)
    #expect(CatalogSnapshotStore.prune([record], sources: [source]).count == 1)

    try FileManager.default.removeItem(at: record.bundleURL)
    #expect(CatalogSnapshotStore.prune([record], sources: [source]).isEmpty)
}

/// An unmounted volume's apps must survive a restart, or the next scan — which
/// reads that source as unreadable and keeps what it already knows — has nothing
/// to keep, and the layout loses their places.
@Test func catalogSnapshotKeepsRecordsOfASourceThatIsNotMounted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (record, source) = try makeSnapshotFixture(in: root)

    // The volume goes away: the root and everything under it.
    try FileManager.default.removeItem(at: root)

    #expect(CatalogSnapshotStore.prune([record], sources: [source]) == [record])
}

@Test func catalogSnapshotStillDropsADeletedAppOfASourceThatIsMounted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (gone, source) = try makeSnapshotFixture(in: root, name: "Gone.app")
    let (kept, _) = try makeSnapshotFixture(in: root, name: "Kept.app")
    try FileManager.default.removeItem(at: gone.bundleURL)

    #expect(CatalogSnapshotStore.prune([gone, kept], sources: [source]) == [kept])
}

@Test func catalogSnapshotEncodingIsBounded() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let (record, _) = try makeSnapshotFixture(in: root)
    let data = try CatalogSnapshotStore.encode(records: Array(repeating: record, count: 4), maximumRecords: 2)
    let decoded = try #require(CatalogSnapshotStore.decode(data, maximumRecords: 2))
    #expect(decoded.count == 2)
}
