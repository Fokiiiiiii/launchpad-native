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
