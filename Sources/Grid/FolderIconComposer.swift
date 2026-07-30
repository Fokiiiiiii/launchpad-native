import AppKit
import Catalog

/// Composites up to 9 of a folder's actual app icons into a fixed 3x3
/// preview tile, matching real macOS Launchpad folder icon conventions —
/// replaces the generic `folder.fill` glyph + count badge this app used
/// before Round 12, Round 12's own hand-drawn-corner mosaic, and Round 14's
/// count-adaptive-shape attempt, in favor of a precise design reference
/// ("Tessera") the user supplied directly: always a 3x3 grid (unfilled
/// slots get a faint placeholder tile, never left blank/uneven), a flat
/// translucent background (no gradient/highlight-stroke baked in here —
/// see below), and a true continuous-corner ("squircle") outer shape.
///
/// The outer squircle clip is deliberately NOT drawn in this bitmap —
/// `NSBezierPath` has no continuous-corner-curve support (unlike SwiftUI's
/// `RoundedRectangle(style: .continuous)` or `CALayer.cornerCurve`), so a
/// hand-drawn rounded-rect here would never match a real macOS app icon's
/// actual corner curve. Instead this draws a plain square tile, and
/// `GridCellItem` clips the whole `iconView` (both this bitmap and real
/// app icons) with `CALayer.cornerCurve = .continuous` — a true squircle,
/// applied once, shared by every icon in the grid.
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

    static func draw(icons: [NSImage], tileSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: tileSize, height: tileSize))
        image.lockFocus()
        defer { image.unlockFocus() }
        let rect = NSRect(x: 0, y: 0, width: tileSize, height: tileSize)

        // Flat, restrained fill — no gradient, no separate highlight stroke.
        // A real user found an earlier gradient+bright-stroke treatment here
        // looked fake/"AI生成っぽい"; the reference design's own folder tile
        // is just a plain 13%-white fill, full stop.
        NSColor.white.withAlphaComponent(0.13).setFill()
        rect.fill()

        // A very subtle top-to-center light falloff — shared by every icon
        // in the grid (see `GridCellItem`), not a folder-specific highlight.
        // Reads as "light catching the material," never a hard edge/border.
        let gradient = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.16),
            NSColor.clear
        ])
        gradient?.draw(from: NSPoint(x: rect.midX, y: rect.maxY), to: NSPoint(x: rect.midX, y: rect.midY))

        // Always a 3x3 grid regardless of actual count — real Launchpad
        // folder icons never resize their internal layout; unfilled slots
        // get a barely-visible placeholder tile instead of being left blank,
        // which is what actually caused the earlier "uneven" look (a
        // half-empty grid with the raw background showing through), not the
        // fixed shape itself.
        let pad = tileSize * 0.13
        let gap = tileSize * 0.055
        let side = (tileSize - pad * 2 - gap * 2) / 3
        let cornerRadius = tileSize * 0.05
        for index in 0..<9 {
            let row = index / 3 // 0 = top row, reading order (left-to-right, top-to-bottom)
            let col = index % 3
            let x = pad + CGFloat(col) * (side + gap)
            let y = pad + CGFloat(2 - row) * (side + gap) // AppKit y-up: flip row->y
            let cellRect = NSRect(x: x, y: y, width: side, height: side)
            if index < icons.count {
                icons[index].draw(in: cellRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            } else {
                NSBezierPath(roundedRect: cellRect, xRadius: cornerRadius, yRadius: cornerRadius)
                    .fill(withColor: NSColor.white.withAlphaComponent(0.06))
            }
        }
        return image
    }
}

private extension NSBezierPath {
    func fill(withColor color: NSColor) {
        color.setFill()
        fill()
    }
}
