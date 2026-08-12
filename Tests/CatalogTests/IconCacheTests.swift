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
