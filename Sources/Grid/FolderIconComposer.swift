import AppKit
import Catalog

/// Composites up to 9 of a folder's actual app icons into a rounded 3x3
/// preview tile, matching real macOS Launchpad folder icons — replaces the
/// generic `folder.fill` glyph + count badge this app used before.
enum FolderIconComposer {
    @MainActor
    static func makeThumbnail(records: [ApplicationRecord], iconCache: IconCache, size: CGFloat) async -> NSImage {
        let previews = Array(records.prefix(9))
        var icons: [NSImage] = []
        for record in previews {
            icons.append(await iconCache.icon(for: record, size: max(size / 3, 24)))
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
        let icons = records.prefix(9).map { iconCache.cachedIconIfAvailable(for: $0) ?? NSImage() }
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
        // Tighter padding/gap than the old 2x2 tile — 9 cells need to read as
        // a dense mosaic (matching real Launchpad's 3x3 folder-preview
        // density), not 4 cells' spacing stretched to fit 9.
        let pad = tileSize * 0.10
        let gap = tileSize * 0.06
        let side = (tileSize - pad * 2 - gap * 2) / 3
        for (index, icon) in icons.prefix(9).enumerated() {
            let row = index / 3 // 0 = top row, reading order (left-to-right, top-to-bottom)
            let col = index % 3
            let x = pad + CGFloat(col) * (side + gap)
            let y = pad + CGFloat(2 - row) * (side + gap) // AppKit y-up: flip row->y
            icon.draw(in: NSRect(x: x, y: y, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        return image
    }
}
