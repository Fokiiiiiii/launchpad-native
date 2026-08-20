import CoreGraphics
import Persistence

/// Keeps the icon inside its slot while allowing the configured scale to
/// remain visible when the surrounding gap provides room. The effective size
/// is applied to the cell's constraints so the icon, label, and hit region
/// share one piece of geometry.
struct GridIconLayoutPolicy {
    static let supportedScaleRange = GridIconScalePreset.supportedScaleRange
    /// Prevents sparse grids (for example 3 columns × 2 rows) from turning
    /// one app into a screen-sized icon. Dense grids remain cell-limited, so
    /// this only affects combinations whose cells have excessive spare room.
    static let maximumDisplayedIconSize: CGFloat = 176

    static func safeSlot(cellSize: CGSize, labelAllowance: CGFloat) -> CGFloat {
        guard cellSize.width.isFinite, cellSize.height.isFinite else { return 1 }
        return max(min(cellSize.width, cellSize.height - labelAllowance), 1)
    }

    static func requestedScale(_ value: Double) -> Double {
        let finiteValue = value.isFinite ? value : 1
        return min(max(finiteValue, supportedScaleRange.lowerBound), supportedScaleRange.upperBound)
    }

    static func maxVisualScale(safeSlot: CGFloat, gap: CGFloat) -> CGFloat {
        let slot = max(safeSlot.isFinite ? safeSlot : 1, 1)
        let spacing = max(gap.isFinite ? gap : 0, 0)
        return min(CGFloat(supportedScaleRange.upperBound), 1 + 0.9 * spacing / slot)
    }

    static func effectiveVisualScale(requestedScale: Double, safeSlot: CGFloat, gap: CGFloat) -> CGFloat {
        min(
            CGFloat(self.requestedScale(requestedScale)),
            maxVisualScale(safeSlot: safeSlot, gap: gap)
        )
    }

    /// Resolves the two values passed to `GridCellItem`: the Auto Layout base
    /// size and the small visual expansion that may use the inter-cell gap.
    /// Keeping this together prevents different row/column combinations from
    /// applying the cap in only one of those two paths.
    static func iconMetrics(
        cellSize: CGSize,
        labelAllowance: CGFloat,
        requestedScale: Double,
        gap: CGFloat
    ) -> (baseSize: CGFloat, visualScale: CGFloat) {
        let slot = safeSlot(cellSize: cellSize, labelAllowance: labelAllowance)
        let scale = effectiveVisualScale(
            requestedScale: requestedScale,
            safeSlot: slot,
            gap: gap
        )
        let baseSize = min(slot, maximumDisplayedIconSize / max(scale, 1))
        return (baseSize, scale)
    }
}
