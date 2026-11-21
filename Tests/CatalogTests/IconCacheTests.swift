import AppKit
import Foundation
import Testing
@testable import Catalog

import Darwin

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

private func bitmapIcon() throws -> NSImage {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1024,
        pixelsHigh: 1024,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ))
    let bytes = try #require(bitmap.bitmapData)
    memset(bytes, 0xa5, bitmap.bytesPerRow * bitmap.pixelsHigh)
    let image = NSImage(size: NSSize(width: 512, height: 512))
    image.addRepresentation(bitmap)
    return image
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

@Test func trimmingPreservesHiddenFilesAndDirectories() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)
    let file = dir.appendingPathComponent("image.png")
    let hidden = dir.appendingPathComponent(".hidden.png")
    let folder = dir.appendingPathComponent("folder.png", isDirectory: true)
    try Data(count: 100).write(to: file)
    try Data(count: 100).write(to: hidden)
    var flagged = dir.appendingPathComponent("flagged.png")
    try Data(count: 100).write(to: flagged)
    var values = URLResourceValues()
    values.isHidden = true
    try flagged.setResourceValues(values)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let external = dir.appendingPathComponent("outside.txt")
    let link = dir.appendingPathComponent("link.png")
    try Data(count: 100).write(to: external)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
    cache.trimDiskCache(toBytes: 0)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(FileManager.default.fileExists(atPath: hidden.path))
    #expect(FileManager.default.fileExists(atPath: flagged.path))
    #expect(FileManager.default.fileExists(atPath: folder.path))
    #expect(FileManager.default.fileExists(atPath: external.path))
    #expect(!FileManager.default.fileExists(atPath: link.path))
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

@Test func diskIconsKeepLogicalSizeAndStayWarmAcrossPages() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let records = (0..<100).map { record("Fixture\($0)", id: "disk-fixture.\($0)") }
    for item in records {
        try png.write(to: cache.cacheFileURL(forKey: "\(item.iconCacheKey)-s128"))
    }
    for item in records {
        let image = await cache.icon(for: item)
        #expect(image.size == NSSize(width: 128, height: 128))
    }
    let warmed = records.filter { cache.cachedIconIfAvailable(for: $0) != nil }.count
    #expect(warmed == records.count, "Only \(warmed) of \(records.count) disk icons remained warm")
}

#if DEBUG
@Test func cancelledPrefetchesReleaseCapacityForVisibleIcons() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)
    cache.setIconLoadsSuspendedForTesting(true)
    defer { cache.setIconLoadsSuspendedForTesting(false) }
    let records = (0..<256).map { record("Cancelled\($0)", id: "cancelled.\($0)") }
    let tasks = records.map { item in Task { await cache.icon(for: item) } }
    for _ in 0..<500 {
        if cache.inFlightCountForTesting() == 256 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(cache.inFlightCountForTesting() == 256)
    for task in tasks { task.cancel() }
    for task in tasks { _ = await task.value }
    #expect(cache.inFlightCountForTesting() == 0)
    let visible = Task { await cache.icon(for: record("Calculator", id: "visible")) }
    try await Task.sleep(for: .milliseconds(50))
    cache.setIconLoadsSuspendedForTesting(false)
    let icon = await visible.value
    #expect(!icon.representations.isEmpty)
}

@Test func anOldCancelledLoadCannotConsumeANewerRequest() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)
    cache.setIconLoadsSuspendedForTesting(true)
    defer { cache.setIconLoadsSuspendedForTesting(false) }
    let app = record("Calculator", id: "same-key")
    let old = Task { await cache.icon(for: app) }
    for _ in 0..<500 {
        if cache.inFlightCountForTesting() == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(cache.inFlightCountForTesting() == 1)
    old.cancel()
    _ = await old.value
    #expect(cache.inFlightCountForTesting() == 0)
    let current = Task { await cache.icon(for: app) }
    for _ in 0..<500 {
        if cache.inFlightCountForTesting() == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(cache.inFlightCountForTesting() == 1)
    cache.setIconLoadsSuspendedForTesting(false)
    let image = await current.value
    #expect(!image.representations.isEmpty)
    #expect(cache.cachedIconIfAvailable(for: app) === image)
}

@Test func cancelledQueuedLoadsAreRemovedFromTheOperationQueue() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)
    cache.setIconLoadsSuspendedForTesting(true)
    defer { cache.setIconLoadsSuspendedForTesting(false) }
    let records = (0..<64).map { record("Queued\($0)", id: "queued.\($0)") }
    let tasks = records.map { item in Task { await cache.icon(for: item) } }
    for _ in 0..<500 {
        if cache.queuedOperationCountForTesting() == 64 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(cache.queuedOperationCountForTesting() == 64)
    for task in tasks { task.cancel() }
    for task in tasks { _ = await task.value }
    #expect(cache.inFlightCountForTesting() == 0)
    cache.setIconLoadsSuspendedForTesting(false)
    for _ in 0..<500 {
        if cache.queuedOperationCountForTesting() == 0 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(cache.queuedOperationCountForTesting() == 0, "cancelled loads stayed queued")
    // Dropped from the queue, not run and returned early: nothing started.
    #expect(cache.loadStartCountForTesting() == 0, "a load nobody was waiting for still started")
}
#endif

@Test func iconMemoryCacheEnforcesCostAndRecentUse() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)
    let a = NSImage(size: NSSize(width: 1024, height: 1024))
    let b = NSImage(size: NSSize(width: 1024, height: 1024))
    let c = NSImage(size: NSSize(width: 1024, height: 1024))
    let d = NSImage(size: NSSize(width: 1024, height: 1024))
    cache.writeMemory("a", a)
    cache.writeMemory("b", b)
    cache.writeMemory("c", c)
    #expect(cache.readMemory("a") === a)
    cache.writeMemory("d", d)
    #expect(cache.readMemory("b") == nil)
    #expect(cache.readMemory("a") === a)
    #expect(cache.readMemory("c") === c)
    #expect(cache.readMemory("d") === d)
    let replacement = NSImage(size: NSSize(width: 1024, height: 1024))
    cache.writeMemory("c", replacement)
    #expect(cache.readMemory("c") === replacement)
    #expect(cache.readMemory("d") === d)
    cache.writeMemory("a", NSImage(size: NSSize(width: 4096, height: 4096)))
    #expect(cache.readMemory("a") == nil)
    #expect(cache.readMemory("c") === replacement)
    cache.evictMemoryCache()
    #expect(cache.readMemory("c") == nil)
    #expect(cache.readMemory("d") == nil)
}

@Test func iconMemoryCacheEnforcesCountAndUnicodeEquivalence() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)
    let icon = NSImage(size: NSSize(width: 1, height: 1))
    for index in 0..<193 { cache.writeMemory("item\(index)", icon) }
    #expect(cache.readMemory("item0") == nil)
    #expect(cache.readMemory("item192") === icon)
    cache.writeMemory("café", icon)
    #expect(cache.readMemory("cafe\u{301}") === icon)
}

@Test func iconMemoryCacheBoundsRealBitmaps() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)
    for index in 0..<13 {
        try autoreleasepool { cache.writeMemory("bitmap\(index)", try bitmapIcon()) }
    }
    #expect(cache.readMemory("bitmap0") == nil)
    #expect(cache.readMemory("bitmap12") != nil)
}

@Test func benchmarkIconMemoryCache() throws {
    guard ProcessInfo.processInfo.environment["LAUNCHPAD_BENCHMARK"] == "1" else { return }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)
    let useRust = ProcessInfo.processInfo.environment["LAUNCHPAD_MEMORY_MODE"] == "icon-rust"
    var legacy: [String: NSImage] = [:]
    func peak() -> Int {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        return usage.ru_maxrss
    }
    let baseline = peak()
    let start = DispatchTime.now().uptimeNanoseconds
    for index in 0..<32 {
        try autoreleasepool {
            let image = try bitmapIcon()
            if useRust { cache.writeMemory("bitmap\(index)", image) }
            else { legacy["bitmap\(index)"] = image }
        }
    }
    if useRust {
        #expect(cache.readMemory("bitmap0") == nil)
        #expect(cache.readMemory("bitmap31") != nil)
    } else {
        #expect(legacy.count == 32)
    }
    print("MEMORY_BENCH scenario=icon-\(useRust ? "rust" : "swift") items=32 baseline_bytes=\(baseline) peak_bytes=\(peak()) elapsed_ns=\(DispatchTime.now().uptimeNanoseconds - start)")
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
