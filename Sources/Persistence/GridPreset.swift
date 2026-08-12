import Foundation

/// Legacy layout density values retained for compatibility with documents and
/// callers from the first preset implementation. The current Settings surface
/// exposes columns and rows directly and uses `GridIconScalePreset` for icon
/// sizing; these geometry presets are no longer presented as the primary UI.
public enum GridPreset: String, CaseIterable, Hashable, Sendable, Identifiable {
    case spacious
    case balanced
    case compact
    case custom

    public var id: String { rawValue }

    public static var selectableCases: [GridPreset] {
        [.spacious, .balanced, .compact]
    }

    public var columns: Int {
        switch self {
        case .spacious: return 6
        case .balanced: return 7
        case .compact: return 8
        case .custom: return 0
        }
    }

    public var rows: Int {
        switch self {
        case .spacious: return 4
        case .balanced, .compact: return 5
        case .custom: return 0
        }
    }

    /// Horizontal cell gap in points.
    public var horizontalSpacing: Double {
        switch self {
        case .spacious: return 28
        case .balanced: return 24
        case .compact: return 20
        case .custom: return 0
        }
    }

    /// Vertical cell gap in points. Compact deliberately keeps a little more
    /// vertical breathing room so labels never collide with enlarged icons.
    public var verticalSpacing: Double {
        switch self {
        case .spacious: return 28
        case .balanced: return 24
        case .compact: return 20
        case .custom: return 0
        }
    }

    /// Outer page margin in points.
    public var pageMargins: Double {
        switch self {
        case .spacious: return 42
        case .balanced, .compact: return 40
        case .custom: return 0
        }
    }

    /// Additional icon multiplier consumed by GridViewController.
    public var iconScale: Double {
        switch self {
        case .spacious: return 1.20
        case .balanced: return 1.16
        case .compact: return 1.10
        case .custom: return 1.00
        }
    }

    public func applying(to current: GridSettings) -> GridSettings {
        guard self != .custom else { return current }
        var updated = current
        updated.columns = columns
        updated.rows = rows
        updated.horizontalSpacing = horizontalSpacing
        updated.verticalSpacing = verticalSpacing
        updated.pageMargins = pageMargins
        updated.iconScale = iconScale
        return updated
    }

    public static func matching(_ settings: GridSettings) -> GridPreset {
        selectableCases.first { preset in
            let geometryMatches =
                preset.columns == settings.columns
                && preset.rows == settings.rows
                && abs(preset.horizontalSpacing - settings.horizontalSpacing) < 0.01
                && abs(preset.verticalSpacing - settings.verticalSpacing) < 0.01
                && abs(preset.pageMargins - settings.pageMargins) < 0.01
            guard geometryMatches else { return false }

            // Documents written before iconScale was introduced decode the
            // legacy fallback (1.05). Balanced geometry must remain selectable
            // instead of being shown as Custom solely because that key was
            // absent; an explicitly different scale still remains Custom.
            let matchesScale = abs(preset.iconScale - settings.iconScale) < 0.01
            let isLegacyBalanced = preset == .balanced && abs(settings.iconScale - 1.05) < 0.01
            return matchesScale || isLegacyBalanced
        } ?? .custom
    }
}

/// Icon-size choices are intentionally independent from the grid geometry.
///
/// `GridPreset` remains available for decoding/compatibility with the first
/// density implementation, but new settings UI should use this enum: changing
/// columns or rows never selects a layout preset or changes the geometry on its
/// own. `smart` resolves against the current grid capacity (and, when known,
/// the available cell size).
public enum GridIconScalePreset: String, CaseIterable, Hashable, Sendable, Identifiable {
    case smart
    case large
    case standard
    case compact
    case custom

    public var id: String { rawValue }

    /// Presets exposed to users. `custom` is a state reported after a manual
    /// scale edit, not a button that changes the value.
    public static var selectableCases: [GridIconScalePreset] {
        [.smart, .large, .standard, .compact]
    }

    /// Safe range exposed by the manual scale control. Values outside this
    /// range would crowd labels or leave excessive unused cell area.
    public static let supportedScaleRange: ClosedRange<Double> = 0.90...1.20

    /// Fixed multipliers for explicit choices. Smart is calculated per grid;
    /// custom has no fixed value and therefore returns nil.
    public var fixedScale: Double? {
        switch self {
        case .smart, .custom: return nil
        case .large: return 1.20
        case .standard: return 1.12
        case .compact: return 1.05
        }
    }

    /// Returns the multiplier to persist for the current grid.
    public func scale(
        columns: Int,
        rows: Int,
        availableCellSize: CGSize? = nil
    ) -> Double? {
        switch self {
        case .smart:
            return Self.recommendedScale(
                columns: columns,
                rows: rows,
                availableCellSize: availableCellSize
            )
        case .large, .standard, .compact:
            return fixedScale
        case .custom:
            return nil
        }
    }

    /// Applies only icon scale; columns, rows, spacing, and margins are kept
    /// exactly as supplied. This is the key separation from `GridPreset`.
    public func applying(to current: GridSettings, availableCellSize: CGSize? = nil) -> GridSettings {
        guard let scale = scale(
            columns: current.columns,
            rows: current.rows,
            availableCellSize: availableCellSize
        ) else { return current }
        var updated = current
        updated.iconScale = scale
        return updated
    }

    /// Computes a sensible multiplier from the current columns × rows. The
    /// values preserve the legacy 6×4/7×5/8×5 recommendations while smoothly
    /// reducing icon size for denser user-defined grids. A cell-size hint keeps
    /// icons from crowding labels on unusually small windows and allows a
    /// little extra breathing room on large displays.
    public static func recommendedScale(
        columns: Int,
        rows: Int,
        availableCellSize: CGSize? = nil
    ) -> Double {
        let capacity = max(columns, 1) * max(rows, 1)
        let capacityScale: Double
        switch capacity {
        case ...24:
            capacityScale = 1.20
        case 25...35:
            capacityScale = 1.20 - Double(capacity - 24) * (0.04 / 11.0)
        case 36...40:
            capacityScale = 1.16 - Double(capacity - 35) * (0.06 / 5.0)
        default:
            capacityScale = max(0.96, 1.10 - Double(capacity - 40) * 0.01)
        }

        let sizeAdjustment: Double
        if let availableCellSize {
            let shortestSide = min(availableCellSize.width, availableCellSize.height)
            switch shortestSide {
            case ..<64: sizeAdjustment = -0.08
            case 64..<80: sizeAdjustment = -0.04
            case 112...: sizeAdjustment = 0.03
            default: sizeAdjustment = 0
            }
        } else {
            sizeAdjustment = 0
        }

        return min(max(capacityScale + sizeAdjustment, supportedScaleRange.lowerBound), supportedScaleRange.upperBound)
    }

    /// Reports which choice describes a persisted scale. Matching is tolerant
    /// of JSON floating-point round trips. Manual edits in the settings model
    /// deliberately mark the state as `.custom` before calling this helper.
    public static func matching(
        _ settings: GridSettings,
        availableCellSize: CGSize? = nil
    ) -> GridIconScalePreset {
        let scale = settings.iconScale
        let tolerance = 0.005
        if abs(scale - recommendedScale(
            columns: settings.columns,
            rows: settings.rows,
            availableCellSize: availableCellSize
        )) < tolerance {
            return .smart
        }
        return selectableCases.dropFirst().first {
            guard let fixedScale = $0.fixedScale else { return false }
            return abs(fixedScale - scale) < tolerance
        } ?? .custom
    }
}

/// Short spelling for callers that do not need the grid-specific prefix.
public typealias IconScalePreset = GridIconScalePreset
