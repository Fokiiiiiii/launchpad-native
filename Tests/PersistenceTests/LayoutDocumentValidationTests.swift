import Foundation
import Testing
@testable import Persistence

/// `layout.json` is read back from disk, where it can be damaged, edited by hand,
/// or written by a newer version. A value that decodes as the right type but is
/// absurd must not reach the arithmetic behind the grid — `columns * rows`
/// traps on overflow, which would crash the app at every launch.

private func decodedDocument(editing edit: (inout [String: Any]) -> Void) throws -> LayoutDocument {
    let encoded = try JSONEncoder().encode(LayoutDocument.empty)
    var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    edit(&json)
    return try JSONDecoder().decode(LayoutDocument.self, from: JSONSerialization.data(withJSONObject: json))
}

private func editingGridSettings(_ edit: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
    { json in
        var settings = json["gridSettings"] as? [String: Any] ?? [:]
        edit(&settings)
        json["gridSettings"] = settings
    }
}

@Test func extremeGridDimensionsAreHeldToSafeBounds() throws {
    for extreme in [Int.max, Int.min, 0, -5, 1_000_000] {
        let document = try decodedDocument(editing: editingGridSettings { settings in
            settings["columns"] = extreme
            settings["rows"] = extreme
            settings["folderGridSize"] = extreme
        })
        let settings = document.gridSettings

        #expect(GridSettings.columnRange.contains(settings.columns), "columns \(extreme)")
        #expect(GridSettings.rowRange.contains(settings.rows), "rows \(extreme)")
        #expect(GridSettings.folderGridSizeRange.contains(settings.folderGridSize), "folderGridSize \(extreme)")
        // The product the grid computes for its page capacity.
        let (_, overflow) = settings.columns.multipliedReportingOverflow(by: settings.rows)
        #expect(!overflow)
    }
}

@Test func spacingMarginsAndScaleAreHeldToSafeBounds() throws {
    let document = try decodedDocument(editing: editingGridSettings { settings in
        settings["horizontalSpacing"] = -50.0
        settings["verticalSpacing"] = 1e9
        settings["pageMargins"] = 1e9
        settings["iconScale"] = 40.0
    })
    let settings = document.gridSettings

    #expect(settings.horizontalSpacing == GridSettings.spacingRange.lowerBound)
    #expect(settings.verticalSpacing == GridSettings.spacingRange.upperBound)
    #expect(settings.pageMargins == GridSettings.marginRange.upperBound)
    #expect(settings.iconScale == GridSettings.iconScaleRange.upperBound)
}

/// What the Settings controls allow must come back exactly as saved.
@Test func valuesTheSettingsControlsOfferAreLeftAlone() throws {
    let document = try decodedDocument(editing: editingGridSettings { settings in
        settings["columns"] = 12
        settings["rows"] = 2
        settings["horizontalSpacing"] = 64.0
        settings["pageMargins"] = 24.0
        settings["iconScale"] = 0.9
    })
    let settings = document.gridSettings

    #expect(settings.columns == 12)
    #expect(settings.rows == 2)
    #expect(settings.horizontalSpacing == 64)
    #expect(settings.pageMargins == 24)
    #expect(settings.iconScale == 0.9)
}

/// A setting written by a newer version, with a value this one does not know,
/// used to fail the whole document — which fell back past the backup and could
/// end at an empty layout.
@Test func anUnknownEnumValueFallsBackForThatOneSettingOnly() throws {
    let document = try decodedDocument(editing: { json in
        json["layoutMode"] = "carousel-from-the-future"
        json["appIconStyle"] = "holographic"
        json["backgroundMode"] = "video"
        json["menuIconVisibility"] = "sometimes"
        var settings = json["gridSettings"] as? [String: Any] ?? [:]
        settings["sortMode"] = "by-colour"
        settings["columns"] = 9
        json["gridSettings"] = settings
    })

    #expect(document.layoutMode == .paged)
    #expect(document.appIconStyle == .classic)
    #expect(document.backgroundMode == .glass)
    #expect(document.menuIconVisibility == .automatic)
    #expect(document.gridSettings.sortMode == .custom)
    // Everything else in the document is intact.
    #expect(document.gridSettings.columns == 9)
}

@Test func glassIntensityStaysBetweenZeroAndOne() throws {
    #expect(try decodedDocument(editing: { $0["glassMaterialIntensity"] = 7.0 }).glassMaterialIntensity == 1)
    #expect(try decodedDocument(editing: { $0["glassMaterialIntensity"] = -3.0 }).glassMaterialIntensity == 0)
}
