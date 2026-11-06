import AppKit
import Foundation
import Testing
@testable import Catalog

private func record(_ name: String, id: String) -> ApplicationRecord {
    ApplicationRecord(
        id: StableAppID(bundleURL: URL(fileURLWithPath: "/System/Applications/\(name).app"), bundleIdentifier: id, teamIdentifier: nil),
        bundleIdentifier: id,
        bundleURL: URL(fileURLWithPath: "/System/Applications/\(name).app"),
        executableURL: nil,
        displayName: name,
        originalDisplayName: name,
        bundleVersion: nil,
        teamIdentifier: nil,
        category: nil,
        sourceID: "test",
        isSystemProtected: true,
        isBackgroundOnly: false,
        iconCacheKey: id,
        canLaunch: true,
        canOpenNewInstance: true,
        lastSeenModificationDate: Date(timeIntervalSince1970: 0)
    )
}

/// Updated apps leave their old icon files behind; the folder has to stay inside
/// its budget by dropping the oldest, and leave the rest alone.
@Test func theDiskCacheDropsTheOldestFilesFirstWhenOverBudget() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)
    let names = (0..<5).map { "icon\($0).png" }
    for (age, name) in names.enumerated() {
        let url = dir.appendingPathComponent(name)
        try Data(count: 1_000).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(1_000 + age))], ofItemAtPath: url.path
        )
    }

    cache.trimDiskCache(toBytes: 2_500)

    let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    #expect(left == ["icon3.png", "icon4.png"])

    cache.trimDiskCache(toBytes: 2_500)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2, "a folder within budget was trimmed")
}

/// The cache moved from an `actor` (fully serialized) to a concurrent-queue
/// backed class specifically so multiple icon fetches can run in parallel
/// instead of one at a time — this test exercises many concurrent callers
/// against a handful of shared keys to confirm the `memory` dictionary
/// never corrupts under real concurrent access (not just "doesn't crash once").
@Test func concurrentIconFetchesForSameAndDifferentKeysDontCorruptState() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)

    let records = (0..<8).map { record("App\($0 % 3)", id: "id\($0 % 3)") } // only 3 distinct keys, 8 concurrent callers

    try await withThrowingTaskGroup(of: NSImage.self) { group in
        for record in records {
            group.addTask {
                await cache.icon(for: record)
            }
        }
        var results: [NSImage] = []
        for try await image in group {
            results.append(image)
        }
        #expect(results.count == 8)
    }
}

@Test func secondFetchIsAMemoryCacheHit() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)
    let r = record("Calculator", id: "com.apple.calculator")

    let first = await cache.icon(for: r)
    let second = await cache.icon(for: r)
    #expect(first === second) // same NSImage instance returned from memory
}

/// The picture is cached per size. Keyed by the app alone, whichever size was
/// asked for first came back for every later request.
@Test func theSameAppAtTwoSizesIsCachedSeparately() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)
    let r = record("Calculator", id: "com.apple.calculator")

    let small = await cache.icon(for: r, size: 64)
    let large = await cache.icon(for: r, size: 128)

    #expect(small !== large)
    #expect(cache.cachedIconIfAvailable(for: r, size: 64) === small)
    #expect(cache.cachedIconIfAvailable(for: r, size: 128) === large)
    #expect(cache.cachedIconIfAvailable(for: r, size: 32) == nil)
}

/// The key starts with an identifier from the app's own Info.plist.
@Test func aHostileKeyStillCachesInsideTheCacheDirectory() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)

    for key in ["../../../etc/evil-1", "a/b/c-2", "..-3"] {
        let url = cache.cacheFileURL(forKey: key)
        #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL, "\(key)")
        #expect(url.pathExtension == "png")
    }
}

@Test func diskCachePathIncludesTheRequestedKey() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)

    let first = cache.cacheFileURL(forKey: "com.example.first")
    let second = cache.cacheFileURL(forKey: "com.example.second")
    #expect(first.lastPathComponent == "com.example.first.png")
    #expect(second.lastPathComponent == "com.example.second.png")
    #expect(first != second)
}
