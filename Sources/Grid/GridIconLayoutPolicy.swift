import CoreGraphics
import Persistence

/// Keeps the icon inside its slot while allowing the configured scale to
/// remain visible when the surrounding gap provides room. The effective size
/// is applied to the cell's constraints so the icon, label, and hit region
/// share one piece of geometry.
struct GridIconLayoutPolicy {
    static let supportedScaleRange = GridIconScalePreset.supportedScaleRange

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
}
