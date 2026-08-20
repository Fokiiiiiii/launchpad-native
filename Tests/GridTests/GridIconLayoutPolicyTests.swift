import CoreGraphics
import Testing
@testable import Grid

@Test func scalesStayOrderedWhenTheGapCanCarryTheExpansion() {
    let safeSlot = GridIconLayoutPolicy.safeSlot(
        cellSize: CGSize(width: 160, height: 180),
        labelAllowance: 23
    )
    let gap: CGFloat = 40
    let scales = [1.00, 1.05, 1.12, 1.20].map {
        GridIconLayoutPolicy.effectiveVisualScale(
            requestedScale: $0,
            safeSlot: safeSlot,
            gap: gap
        )
    }

    for (actual, expected) in zip(scales, [1.00, 1.05, 1.12, 1.20]) {
        #expect(abs(actual - expected) < 0.0001)
    }
}

@Test func narrowGapsCapVisualScaleWithoutChangingTheSafeSlot() {
    let safeSlot = GridIconLayoutPolicy.safeSlot(
        cellSize: CGSize(width: 120, height: 143),
        labelAllowance: 23
    )
    let maximum = GridIconLayoutPolicy.maxVisualScale(safeSlot: safeSlot, gap: 1)
    let scales = [1.00, 1.05, 1.12, 1.20].map {
        GridIconLayoutPolicy.effectiveVisualScale(
            requestedScale: $0,
            safeSlot: safeSlot,
            gap: 1
        )
    }

    #expect(safeSlot == 120)
    #expect(maximum < 1.05)
    #expect(scales[0] <= scales[1])
    #expect(scales[1] <= scales[2])
    #expect(scales[2] <= scales[3])
    #expect(scales.allSatisfy { $0 <= maximum })
}

@Test func requestedScaleAndSpacingAreClampedAtTrustBoundaries() {
    #expect(GridIconLayoutPolicy.requestedScale(0.1) == 0.90)
    #expect(GridIconLayoutPolicy.requestedScale(2.0) == 1.20)
    #expect(GridIconLayoutPolicy.maxVisualScale(safeSlot: 100, gap: -4) == 1)
    #expect(GridIconLayoutPolicy.safeSlot(cellSize: .zero, labelAllowance: 23) == 1)
}

@Test func everySupportedRowAndColumnCombinationKeepsAStableIconGroup() {
    let viewport = CGSize(width: 1_680, height: 932)
    let margin: CGFloat = 42
    let spacing: CGFloat = 28

    for columns in 3...12 {
        for rows in 2...8 {
            let cellSize = CGSize(
                width: (viewport.width - margin * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns),
                height: (viewport.height - margin * 2 - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            )
            let metrics = GridIconLayoutPolicy.iconMetrics(
                cellSize: cellSize,
                labelAllowance: 23,
                requestedScale: 1.20,
                gap: spacing
            )
            let displayedSize = metrics.baseSize * metrics.visualScale
            let labelGroupHeight = displayedSize + 5 + 14

            #expect(displayedSize.isFinite)
            #expect(displayedSize > 0)
            #expect(displayedSize <= GridIconLayoutPolicy.maximumDisplayedIconSize + 0.001)
            // The expansion is allowed to consume the configured gap, but it
            // must never make the icon/label group overflow its slot plus that
            // gap and clip at the next row.
            #expect(labelGroupHeight <= cellSize.height + spacing + 0.001, "columns=\(columns), rows=\(rows)")
        }
    }
}
