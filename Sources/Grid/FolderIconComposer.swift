import AppKit
import Catalog

/// Composites up to 9 of a folder's actual app icons into a preview tile
/// whose internal grid shape adapts to the actual icon count (1x1 through
/// 3x3 — see `gridShape(forIconCount:)`), matching real macOS/iOS folder
/// icon conventions — replaces the generic `folder.fill` glyph + count
/// badge this app used before Round 12, and Round 12's own fixed-3x3-
/// regardless-of-count layout before Round 14.
enum FolderIconComposer {
    @MainActor
    static func makeThumbnail(records: [ApplicationRecord], iconCache: IconCache, size: CGFloat) async -> NSImage {
        let previews = Array(records.prefix(9))
        let shape = gridShape(forIconCount: previews.count)
        // Fetch at the actual per-icon draw resolution (derived from the
        // adaptive shape) rather than a fixed /3 — a 2x2 folder's mini-icons
        // render at roughly tileSize/2, so fetching at /3 would upscale a
        // smaller cached bitmap and undo the legibility win of fewer slots.
        let divisor = max(shape.columns, shape.rows)
        let fetchSize = max(size / CGFloat(divisor), 24)
        var icons: [NSImage] = []
        for record in previews {
            icons.append(await iconCache.icon(for: record, size: fetchSize))
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

    /// Pure, no I/O — maps how many app icons a folder actually has to the
    /// (columns, rows) mosaic shape it should render as. Real macOS/iOS
    /// folder-preview convention: fewer apps get a denser, larger-icon
    /// arrangement instead of a fixed 3x3 with blank trailing slots (the
    /// direct cause of a real user report that folders with fewer than 9
    /// apps looked "uneven"). `internal` (not `private`) so
    /// `Tests/GridTests` can exercise it directly via `@testable import`.
    static func gridShape(forIconCount count: Int) -> (columns: Int, rows: Int) {
        switch max(count, 0) {
        case 0, 1: return (1, 1)
        case 2: return (2, 1)
        case 3, 4: return (2, 2)
        case 5, 6: return (3, 2)
        default: return (3, 3) // 7...9 (callers already cap at 9 via .prefix(9))
        }
    }

    static func draw(icons: [NSImage], tileSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: tileSize, height: tileSize))
        image.lockFocus()
        defer { image.unlockFocus() }
        let rect = NSRect(x: 0, y: 0, width: tileSize, height: tileSize)
        let corner = tileSize * 0.22
        let background = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        background.addClip()

        // A subtle top-to-bottom gradient + thin top-edge highlight instead
        // of a flat static fill — a real user found the old flat white
        // overlay "looks cheap" (背景が安っぽく見える). Matches this app's
        // established glass visual language (search bar, page control,
        // folder popover) and apple-design's material guidance ("a bright
        // top edge reads as light catching the material").
        let gradient = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.30),
            NSColor.white.withAlphaComponent(0.14)
        ])
        gradient?.draw(from: NSPoint(x: rect.midX, y: rect.maxY), to: NSPoint(x: rect.midX, y: rect.minY))

        let highlightInset = corner * 0.6
        let highlightLineWidth = max(1, tileSize * 0.012)
        let topHighlight = NSBezierPath()
        topHighlight.lineCapStyle = .round
        topHighlight.lineWidth = highlightLineWidth
        topHighlight.move(to: NSPoint(x: rect.minX + highlightInset, y: rect.maxY - highlightLineWidth))
        topHighlight.line(to: NSPoint(x: rect.maxX - highlightInset, y: rect.maxY - highlightLineWidth))
        NSColor.white.withAlphaComponent(0.45).setStroke()
        topHighlight.stroke()

        // Adaptive mosaic: shape depends on actual icon count, not a fixed
        // 3x3 — see `gridShape(forIconCount:)`'s doc comment.
        let shape = gridShape(forIconCount: icons.count)
        let pad = tileSize * 0.10
        let gap = tileSize * 0.06
        let availableWidth = tileSize - pad * 2 - gap * CGFloat(shape.columns - 1)
        let availableHeight = tileSize - pad * 2 - gap * CGFloat(shape.rows - 1)
        let side = min(availableWidth / CGFloat(shape.columns), availableHeight / CGFloat(shape.rows))
        let gridHeight = CGFloat(shape.rows) * side + CGFloat(shape.rows - 1) * gap
        let originY = (tileSize - gridHeight) / 2

        var index = 0
        var remaining = icons.count
        for row in 0..<shape.rows {
            let countInRow = min(shape.columns, remaining)
            remaining -= countInRow
            guard countInRow > 0 else { continue }
            // Centers a partial last row under the full tile width (e.g. 5
            // icons in a 3x2 shape: row 0 has 3, row 1 has 2, centered)
            // rather than left-aligning it under the first N columns.
            let rowWidth = CGFloat(countInRow) * side + CGFloat(countInRow - 1) * gap
            let rowOriginX = (tileSize - rowWidth) / 2
            let y = originY + CGFloat(shape.rows - 1 - row) * (side + gap) // AppKit y-up: flip row->y
            for col in 0..<countInRow {
                guard index < icons.count else { break }
                let x = rowOriginX + CGFloat(col) * (side + gap)
                icons[index].draw(in: NSRect(x: x, y: y, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1.0)
                index += 1
            }
        }
        return image
    }
}
