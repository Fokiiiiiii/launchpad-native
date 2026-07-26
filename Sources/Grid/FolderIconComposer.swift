import AppKit
import Catalog

/// Composites up to 4 of a folder's actual app icons into a rounded 2x2
/// preview tile, matching real iOS/macOS Springboard-style folder icons —
/// replaces the generic `folder.fill` glyph + count badge this app used
/// before.
enum FolderIconComposer {
    @MainActor
    static func makeThumbnail(records: [ApplicationRecord], iconCache: IconCache, size: CGFloat) async -> NSImage {
        let previews = Array(records.prefix(4))
        var icons: [NSImage] = []
        for record in previews {
            icons.append(await iconCache.icon(for: record, size: max(size / 2, 32)))
        }
        return draw(icons: icons, tileSize: size)
    }

    /// Synchronous variant for `SnapshotDataSource` (`GridViewController`'s
    /// offscreen page-drag snapshot renderer): that render path is entirely
    /// synchronous by design — "no async work happens between here and the
    /// function returning" per its own doc comment, and the temporary
    /// collection view/host window are torn down immediately after the
    /// bitmap is captured — so an async fetch-then-apply here would resolve
    /// too late (if at all) to ever paint. Mirrors how the same data source
    /// already treats app icons via `IconCache.cachedIconIfAvailable`: a
    /// best-effort peek at whatever's already warm in memory, falling back
    /// to a blank slot per icon on a cache miss rather than blocking.
    static func makeThumbnailSync(records: [ApplicationRecord], iconCache: IconCache, size: CGFloat) -> NSImage {
        let icons = records.prefix(4).map { iconCache.cachedIconIfAvailable(for: $0) ?? NSImage() }
        return draw(icons: Array(icons), tileSize: size)
    }

    static func placeholderTile(size: CGFloat) -> NSImage {
        draw(icons: [], tileSize: size)
    }

    private static func draw(icons: [NSImage], tileSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: tileSize, height: tileSize))
        image.lockFocus()
        defer { image.unlockFocus() }
        let rect = NSRect(x: 0, y: 0, width: tileSize, height: tileSize)
        let corner = tileSize * 0.22
        let background = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        NSColor.white.withAlphaComponent(0.18).setFill()
        background.fill()
        background.addClip()
        let pad = tileSize * 0.14
        let gap = tileSize * 0.08
        let side = (tileSize - pad * 2 - gap) / 2
        let slots: [(Int, Int)] = [(0, 1), (1, 1), (0, 0), (1, 0)] // TL, TR, BL, BR (AppKit y-up)
        for (index, icon) in icons.prefix(4).enumerated() {
            let (columnIndex, rowIndex) = slots[index]
            let x = pad + CGFloat(columnIndex) * (side + gap)
            let y = pad + CGFloat(rowIndex) * (side + gap)
            icon.draw(in: NSRect(x: x, y: y, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        return image
    }
}
