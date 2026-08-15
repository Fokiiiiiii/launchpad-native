import CoreGraphics
import Foundation

/// The page-grid's slot arithmetic, free of AppKit and of any drag state, so
/// it can be unit-tested directly — same role `GridIconLayoutPolicy` plays for
/// icon sizing.
///
/// This exists because the identical `column = slot % columns` /
/// `row = slot / columns` / `x = margin + column * (cellWidth + spacing)`
/// arithmetic was written out three separate times: in `PagedGridLayout`
/// (which positions the real cells), and twice inside `GridViewController`
/// (`frameForSlot`, which the drag hysteresis measures against, and
/// `insertionSlot`, which maps a pointer back to a slot). Those three had to
/// agree exactly or a drag would highlight one cell and drop into another,
/// and nothing enforced that they did. `GridSlotGeometryTests` now pins the
/// layout and this type to the same answer.
struct GridSlotGeometry {
    /// Distance from one slot's leading edge to the next one's, along each
    /// axis. Clamped to at least 1 so a degenerate configuration can't divide
    /// by zero when mapping a point back to a slot.
    static func strides(cellSize: CGSize, horizontalSpacing: CGFloat, verticalSpacing: CGFloat) -> (column: CGFloat, row: CGFloat) {
        (
            column: max(cellSize.width + horizontalSpacing, 1),
            row: max(cellSize.height + verticalSpacing, 1)
        )
    }

    /// The frame a given slot occupies within its own page, in the page's
    /// local coordinates (i.e. excluding any per-page horizontal offset).
    static func frameForSlot(
        _ slot: Int,
        columns: Int,
        cellSize: CGSize,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat,
        margin: CGFloat
    ) -> CGRect {
        let columns = max(columns, 1)
        let column = slot % columns
        let row = slot / columns
        return CGRect(
            x: margin + CGFloat(column) * (cellSize.width + horizontalSpacing),
            y: margin + CGFloat(row) * (cellSize.height + verticalSpacing),
            width: cellSize.width,
            height: cellSize.height
        )
    }

    /// Maps a point in page-local coordinates to the slot a drop there should
    /// target.
    ///
    /// - Parameter occupiedSlots: how many slots the drop may choose between.
    ///   Callers pass the page's item count, minus one when the dragged item
    ///   itself still occupies a slot on this page (that slot is freed by the
    ///   move). The result is clamped to this, which is what turns a pointer
    ///   over the trailing empty area into "append at the end".
    ///
    /// The column is clamped *before* being combined with the row: without
    /// that, a point past the right edge would overflow into the first column
    /// of the next row, so releasing to the right of the last icon in a row
    /// would insert somewhere unrelated instead of at the end of that row.
    static func insertionSlot(
        forPoint point: CGPoint,
        columns: Int,
        cellSize: CGSize,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat,
        margin: CGFloat,
        occupiedSlots: Int
    ) -> Int {
        let columns = max(columns, 1)
        let stride = strides(cellSize: cellSize, horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing)
        let rawColumn = Int(floor((point.x - margin) / stride.column))
        let clampedColumn = min(max(rawColumn, 0), columns - 1)
        let rawRow = max(Int(floor((point.y - margin) / stride.row)), 0)
        let slot = rawRow * columns + clampedColumn
        return min(max(slot, 0), max(occupiedSlots, 0))
    }

    /// Whether the pointer has moved far enough from the committed slot's
    /// center to consider a different slot.
    ///
    /// Straight-line distance, deliberately, not a per-axis comparison: an
    /// earlier version tested `point.x` alone, so dragging straight up or down
    /// onto another row — where `x` barely changes — could never satisfy it,
    /// and the icon under the pointer would refuse to move out of the way no
    /// matter how far the drag went.
    static func exceedsHysteresis(
        point: CGPoint,
        committedFrame: CGRect,
        fraction: CGFloat
    ) -> Bool {
        let dx = point.x - committedFrame.midX
        let dy = point.y - committedFrame.midY
        let radius = min(committedFrame.width, committedFrame.height) * fraction
        return dx * dx + dy * dy > radius * radius
    }

    /// Where a preview slot lands once the dragged item is taken out of the
    /// running order and re-inserted at `candidateSlot`.
    ///
    /// Callers walk the page's items in order, skipping the dragged one, and
    /// feed the running position of each remaining item. The mapping must be a
    /// permutation — every destination distinct, no gaps — or the live preview
    /// stacks two icons in one slot and leaves another empty.
    static func previewSlot(naturalPosition: Int, candidateSlot: Int) -> Int {
        naturalPosition < candidateSlot ? naturalPosition : naturalPosition + 1
    }

    /// The centered sub-rectangle of a cell that counts as "drop onto this app
    /// to make a folder", as a fraction inset on the shorter edge.
    static func folderZone(in frame: CGRect, inset fraction: CGFloat) -> CGRect {
        let inset = min(frame.width, frame.height) * fraction
        return frame.insetBy(dx: inset, dy: inset)
    }
}
