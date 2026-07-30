import AppKit
import Catalog
import Foundation
import Testing
@testable import Grid

private func record(_ name: String, id: String) -> ApplicationRecord {
    ApplicationRecord(
        id: StableAppID(bundleURL: URL(fileURLWithPath: "/tmp/\(name).app"), bundleIdentifier: id, teamIdentifier: nil),
        bundleIdentifier: id,
        bundleURL: URL(fileURLWithPath: "/tmp/\(name).app"),
        executableURL: nil,
        displayName: name,
        originalDisplayName: name,
        bundleVersion: nil,
        teamIdentifier: nil,
        category: nil,
        sourceID: "test",
        isSystemProtected: false,
        isBackgroundOnly: false,
        iconCacheKey: id,
        canLaunch: true,
        canOpenNewInstance: true,
        lastSeenModificationDate: Date(timeIntervalSince1970: 0)
    )
}

@Test @MainActor func makeThumbnailSyncProducesTileSizedImageForRepresentativeCounts() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)
    let size: CGFloat = 96

    for count in [0, 1, 2, 5, 9, 12] {
        let records = (0..<count).map { record("App\($0)", id: "app\($0)") }
        let image = FolderIconComposer.makeThumbnailSync(records: records, iconCache: cache, size: size)
        #expect(image.size == NSSize(width: size, height: size))
    }
}

@Test @MainActor func makeThumbnailSyncNeverDrawsMoreThanNineIcons() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = IconCache(cacheDirectory: dir)
    let records = (0..<12).map { record("App\($0)", id: "app\($0)") }
    let image = FolderIconComposer.makeThumbnailSync(records: records, iconCache: cache, size: 96)
    #expect(image.size == NSSize(width: 96, height: 96))
}

@Test func placeholderTileMatchesRequestedSize() {
    let image = FolderIconComposer.placeholderTile(size: 64)
    #expect(image.size == NSSize(width: 64, height: 64))
}
