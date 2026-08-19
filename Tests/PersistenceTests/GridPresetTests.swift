import Foundation
import Testing
@testable import Persistence

@Test func iconScalePresetLeavesGeometryUntouched() {
    let base = GridSettings.default
    let updated = GridIconScalePreset.large.applying(to: base)

    #expect(updated.columns == base.columns)
    #expect(updated.rows == base.rows)
    #expect(updated.horizontalSpacing == base.horizontalSpacing)
    #expect(updated.verticalSpacing == base.verticalSpacing)
    #expect(updated.pageMargins == base.pageMargins)
    #expect(updated.iconScale == 1.20)
    #expect(GridIconScalePreset.matching(updated) == .large)
}

@Test func smartIconScaleFollowsCurrentCapacity() {
    var sparse = GridSettings.default
    sparse.columns = 6
    sparse.rows = 4
    var dense = sparse
    dense.columns = 10
    dense.rows = 6

    let sparseScale = GridIconScalePreset.smart.applying(to: sparse).iconScale
    let denseScale = GridIconScalePreset.smart.applying(to: dense).iconScale

    #expect(sparseScale == 1.20)
    #expect(denseScale < sparseScale)
    #expect(denseScale >= 0.96)
}

@Test func manuallyAdjustedIconScaleIsCustom() {
    var settings = GridIconScalePreset.smart.applying(to: GridSettings.default)
    settings.iconScale = 1.13

    #expect(GridIconScalePreset.matching(settings) == .custom)
}

@Test func legacyGridSettingsWithoutIconScaleUseSafeFallback() throws {
    let payload = """
    {
      "columns": 7,
      "rows": 5,
      "horizontalSpacing": 24,
      "verticalSpacing": 24,
      "labelVisible": true,
      "labelLineCount": 2,
      "pageMargins": 40,
      "folderGridSize": 9,
      "sortMode": "custom"
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(GridSettings.self, from: payload)
    #expect(decoded.iconScale == 1.05)
    #expect(decoded.columns == 7)
    #expect(decoded.rows == 5)
}
