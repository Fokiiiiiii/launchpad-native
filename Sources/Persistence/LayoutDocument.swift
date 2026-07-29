import Foundation

/// A stable identity for one installed application. Mirrors `Catalog.StableAppID`
/// structurally (same hash, same equality) without Persistence depending on
/// Catalog — the two modules are decoupled per the architecture's module
/// boundaries; conversion happens at the composition layer that depends on both.
public struct StableAppIdentifier: Hashable, Codable, Sendable {
    public let value: String
    public init(value: String) { self.value = value }
}

public struct FolderID: Hashable, Codable, Sendable {
    public let value: String
    public init(value: String = UUID().uuidString) { self.value = value }
}

public enum LayoutItem: Codable, Hashable, Sendable {
    case app(StableAppIdentifier)
    case folder(FolderID)
}

public struct Folder: Codable, Sendable, Hashable {
    public var id: FolderID
    public var name: String
    public var pages: [[LayoutItem]]

    public init(id: FolderID = FolderID(), name: String, pages: [[LayoutItem]] = [[]]) {
        self.id = id
        self.name = name
        self.pages = pages
    }
}

public enum LayoutMode: String, Codable, Sendable {
    case paged
    case verticalScroll
}

/// "カスタム" (manual drag order, unchanged), "名前順" (alphabetical by
/// display name, including aliases), "追加日順" (newest-added first — see
/// `LayoutDocument.dateAddedByID`), or "最終使用日順" (most-recently-launched
/// first — see `LayoutDocument.lastUsedByID`). Adding new raw-`String`
/// cases here is backward compatible on its own (an old `layout.json` never
/// contains a raw value that didn't exist yet when it was written) — unlike
/// adding a new *stored property* to a `Codable` struct, no `decodeIfPresent`
/// dance is needed for the enum itself.
public enum SortMode: String, Codable, Sendable {
    case custom
    case name
    case dateAdded
    case lastUsed
}

/// Selectable app-icon designs — all original artwork (see
/// `Tools/IconGenerator`), never a reproduction of Apple's or any
/// competitor's actual icon. Adding new raw-`String` cases here is
/// backward compatible on its own, same reasoning as `SortMode` above.
public enum AppIconStyle: String, Codable, Sendable, CaseIterable {
    case classic
    case monochrome
    case solid
    case diagonal
}

/// Populated in Phase 6 (Customization); present now so the schema doesn't
/// need a migration just to add it later.
///
/// Uses a hand-written `Codable` implementation (`decodeIfPresent(...) ??
/// default`) rather than the synthesized one: a synthesized decoder
/// requires every key present in the JSON, so adding a field like
/// `sortMode` here would fail to decode any `layout.json` saved before
/// that field existed — the whole document would then fall back past the
/// last-known-good backup (usually written in the same pre-change schema)
/// straight to `LayoutDocument.empty`, silently wiping the user's real
/// grid. This same risk applies to `TriggerSettings` and `LayoutDocument`
/// below — all three now decode new fields leniently for exactly this
/// reason.
public struct GridSettings: Codable, Sendable, Hashable {
    public var columns: Int
    public var rows: Int
    public var iconSize: Double
    public var horizontalSpacing: Double
    public var verticalSpacing: Double
    public var labelVisible: Bool
    public var labelLineCount: Int
    public var pageMargins: Double
    public var folderGridSize: Int
    public var sortMode: SortMode

    public init(
        columns: Int,
        rows: Int,
        iconSize: Double,
        horizontalSpacing: Double,
        verticalSpacing: Double,
        labelVisible: Bool,
        labelLineCount: Int,
        pageMargins: Double,
        folderGridSize: Int,
        sortMode: SortMode = .custom
    ) {
        self.columns = columns
        self.rows = rows
        self.iconSize = iconSize
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.labelVisible = labelVisible
        self.labelLineCount = labelLineCount
        self.pageMargins = pageMargins
        self.folderGridSize = folderGridSize
        self.sortMode = sortMode
    }

    private enum CodingKeys: String, CodingKey {
        case columns, rows, iconSize, horizontalSpacing, verticalSpacing, labelVisible, labelLineCount, pageMargins, folderGridSize, sortMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = try container.decode(Int.self, forKey: .columns)
        rows = try container.decode(Int.self, forKey: .rows)
        iconSize = try container.decode(Double.self, forKey: .iconSize)
        horizontalSpacing = try container.decode(Double.self, forKey: .horizontalSpacing)
        verticalSpacing = try container.decode(Double.self, forKey: .verticalSpacing)
        labelVisible = try container.decode(Bool.self, forKey: .labelVisible)
        labelLineCount = try container.decode(Int.self, forKey: .labelLineCount)
        pageMargins = try container.decode(Double.self, forKey: .pageMargins)
        folderGridSize = try container.decode(Int.self, forKey: .folderGridSize)
        sortMode = try container.decodeIfPresent(SortMode.self, forKey: .sortMode) ?? .custom
    }

    public static let `default` = GridSettings(
        columns: 7,
        rows: 5,
        iconSize: 96,
        horizontalSpacing: 24,
        verticalSpacing: 32,
        labelVisible: true,
        labelLineCount: 2,
        pageMargins: 48,
        folderGridSize: 9,
        sortMode: .custom
    )
}

/// Populated in Phase 6; reserved now.
public struct CustomSourceConfig: Codable, Sendable, Hashable {
    public var id: String
    public var rootPath: String
    public var recursive: Bool
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    public var priority: Int
    public var enabled: Bool

    public init(
        id: String,
        rootPath: String,
        recursive: Bool,
        includeGlobs: [String],
        excludeGlobs: [String],
        priority: Int,
        enabled: Bool
    ) {
        self.id = id
        self.rootPath = rootPath
        self.recursive = recursive
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.priority = priority
        self.enabled = enabled
    }
}

/// Populated in Phase 5; reserved now.
///
/// Hand-written `Codable` (see `GridSettings`'s doc comment for why):
/// `multitouchFingerCount` was added after this struct already had real
/// saved data on disk, and a synthesized decoder would fail closed on any
/// `layout.json` missing that key.
/// A snapshot of what this app overwrote in another app's own trackpad
/// preference domains (`com.apple.AppleMultitouchTrackpad`/
/// `com.apple.driver.AppleBluetoothMultitouch.trackpad`) to disable a
/// conflicting system pinch gesture — see `Triggers.ConflictingGestureManager`.
/// `values`' entries being `nil` (i.e. the dictionary's optional Int value,
/// not a missing key) means "this domain didn't have the key set at all
/// before" — distinct from `0` ("existed, was already off") — so restoring
/// can put back the exact prior state rather than assuming a default.
public struct GestureConflictBackup: Codable, Sendable, Equatable {
    public var fingerCount: Int
    public var values: [String: Int?]

    public init(fingerCount: Int, values: [String: Int?]) {
        self.fingerCount = fingerCount
        self.values = values
    }
}

public struct TriggerSettings: Codable, Sendable, Equatable {
    public var hotkeyEnabled: Bool
    public var hotkeyKeyCode: UInt16?
    public var hotkeyModifierFlags: UInt
    public var hotCornersEnabled: [String: Bool] // "topLeft"/"topRight"/"bottomLeft"/"bottomRight" -> enabled
    public var f4Enabled: Bool
    public var multitouchGestureEnabled: Bool
    public var multitouchSensitivity: Double
    /// 4 or 5 — Settings only offers those two (3-finger was dropped as a
    /// selectable option per explicit user request; see
    /// `PinchGestureRecognizer`'s doc comment for the history).
    public var multitouchFingerCount: Int
    /// Whether this app should keep macOS's own conflicting trackpad pinch
    /// gesture (for whichever finger count is currently configured) forced
    /// off — see `Triggers.ConflictingGestureManager`. `gestureConflictBackup`
    /// is the corresponding restore-point, non-nil exactly while this is
    /// actively applied.
    public var gestureConflictPreventionEnabled: Bool
    public var gestureConflictBackup: GestureConflictBackup?

    public init(
        hotkeyEnabled: Bool,
        hotkeyKeyCode: UInt16?,
        hotkeyModifierFlags: UInt,
        hotCornersEnabled: [String: Bool],
        f4Enabled: Bool,
        multitouchGestureEnabled: Bool,
        multitouchSensitivity: Double,
        multitouchFingerCount: Int,
        gestureConflictPreventionEnabled: Bool,
        gestureConflictBackup: GestureConflictBackup?
    ) {
        self.hotkeyEnabled = hotkeyEnabled
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifierFlags = hotkeyModifierFlags
        self.hotCornersEnabled = hotCornersEnabled
        self.f4Enabled = f4Enabled
        self.multitouchGestureEnabled = multitouchGestureEnabled
        self.multitouchSensitivity = multitouchSensitivity
        self.multitouchFingerCount = multitouchFingerCount
        self.gestureConflictPreventionEnabled = gestureConflictPreventionEnabled
        self.gestureConflictBackup = gestureConflictBackup
    }

    private enum CodingKeys: String, CodingKey {
        case hotkeyEnabled, hotkeyKeyCode, hotkeyModifierFlags, hotCornersEnabled, f4Enabled, multitouchGestureEnabled, multitouchSensitivity, multitouchFingerCount, gestureConflictPreventionEnabled, gestureConflictBackup
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkeyEnabled = try container.decode(Bool.self, forKey: .hotkeyEnabled)
        hotkeyKeyCode = try container.decodeIfPresent(UInt16.self, forKey: .hotkeyKeyCode)
        hotkeyModifierFlags = try container.decode(UInt.self, forKey: .hotkeyModifierFlags)
        hotCornersEnabled = try container.decode([String: Bool].self, forKey: .hotCornersEnabled)
        f4Enabled = try container.decode(Bool.self, forKey: .f4Enabled)
        multitouchGestureEnabled = try container.decode(Bool.self, forKey: .multitouchGestureEnabled)
        multitouchSensitivity = try container.decode(Double.self, forKey: .multitouchSensitivity)
        multitouchFingerCount = try container.decodeIfPresent(Int.self, forKey: .multitouchFingerCount) ?? 4
        gestureConflictPreventionEnabled = try container.decodeIfPresent(Bool.self, forKey: .gestureConflictPreventionEnabled) ?? false
        gestureConflictBackup = try container.decodeIfPresent(GestureConflictBackup.self, forKey: .gestureConflictBackup)
    }

    // hotCornersEnabled defaults with bottomRight on: real hands-on testing
    // found that relying on the 4-finger gesture alone left no
    // *discoverable* trigger for a first-time user — nobody finds a pinch
    // gesture by accident the way they'd notice a screen corner.
    // bottomRight matches classic Launchpad's own hot-corner convention.
    // F4 needs Input Monitoring permission this app bundle doesn't request
    // yet; the hotkey needs a key code, which the Settings UI now lets you
    // record (see HotkeyRecorderView) but still defaults to off until you
    // set one.
    //
    // multitouchGestureEnabled defaults to false (flipped back from an
    // earlier true default): real hands-on testing found the 4-finger
    // pinch/spread collides with macOS's own default trackpad gesture
    // assignment for Launchpad/Mission Control — both this app's raw
    // MultitouchSupport listener and the system's own handler react to the
    // same physical gesture at once, which read as "barely usable," not a
    // bug in the gesture-matching logic itself. The hot corner (above) and
    // a user-recordable hotkey are enough of a discoverable default trigger
    // set without needing a gesture that fights the OS for the same input.
    public static let `default` = TriggerSettings(
        hotkeyEnabled: false,
        hotkeyKeyCode: nil,
        hotkeyModifierFlags: 0,
        hotCornersEnabled: ["bottomRight": true],
        f4Enabled: true,
        multitouchGestureEnabled: false,
        multitouchSensitivity: 0.5,
        multitouchFingerCount: 4,
        gestureConflictPreventionEnabled: false,
        gestureConflictBackup: nil
    )
}

/// The full persisted state of the launcher, versioned for migration.
///
/// Hand-written `Codable` for the same reason as `GridSettings`/
/// `TriggerSettings` above: this is the outermost document, so any missing
/// key here (from a field added after real `layout.json` files already
/// existed) is what actually triggers the fall-through past the last-
/// known-good backup to `.empty` — the failure mode that motivated this
/// pattern in the first place.
public struct LayoutDocument: Codable, Sendable {
    public var schemaVersion: Int
    public var layoutMode: LayoutMode
    public var gridSettings: GridSettings
    public var pages: [[LayoutItem]]
    public var folders: [FolderID: Folder]
    public var itemOrder: [StableAppIdentifier]
    public var aliases: [StableAppIdentifier: String]
    public var hiddenApplicationIDs: Set<StableAppIdentifier>
    public var customSources: [CustomSourceConfig]
    public var triggerSettings: TriggerSettings
    public var lastSelectedPage: Int
    public var lastScrollPosition: Double
    /// When on, the launcher paints *over* the real Dock (pre-Phase-14
    /// behavior) instead of sitting one level below it — see
    /// `LauncherWindow`'s level calculation.
    public var hideDockWhileLauncherOpen: Bool
    /// When each app was first placed onto a page/into a folder — the basis
    /// for `SortMode.dateAdded`. Apps placed before this field existed have
    /// no entry here; `GridModel.backfillMissingDateAdded()` fills those in
    /// lazily using each app's existing position as a proxy for "roughly
    /// when added," rather than leaving them all tied at "unknown."
    public var dateAddedByID: [StableAppIdentifier: Date]
    /// When each app was last actually launched — the basis for
    /// `SortMode.lastUsed`. An app never launched (or launched before this
    /// field existed) simply has no entry; sorting treats that as
    /// `.distantPast` (see `GridModel`'s sort comparators), so never-used
    /// apps sink to the end under a "most recent first" sort rather than
    /// contaminating the order of apps that do have real data.
    public var lastUsedByID: [StableAppIdentifier: Date]
    /// The app's own selected icon design — an app-wide preference (not a
    /// grid layout setting, so it lives as a top-level field rather than
    /// nested in `GridSettings`). Applied at runtime via
    /// `NSApp.applicationIconImage`; see `Settings.AppIconStyleApplier`.
    public var appIconStyle: AppIconStyle

    public init(
        schemaVersion: Int,
        layoutMode: LayoutMode,
        gridSettings: GridSettings,
        pages: [[LayoutItem]],
        folders: [FolderID: Folder],
        itemOrder: [StableAppIdentifier],
        aliases: [StableAppIdentifier: String],
        hiddenApplicationIDs: Set<StableAppIdentifier>,
        customSources: [CustomSourceConfig],
        triggerSettings: TriggerSettings,
        lastSelectedPage: Int,
        lastScrollPosition: Double,
        hideDockWhileLauncherOpen: Bool = false,
        dateAddedByID: [StableAppIdentifier: Date] = [:],
        lastUsedByID: [StableAppIdentifier: Date] = [:],
        appIconStyle: AppIconStyle = .classic
    ) {
        self.schemaVersion = schemaVersion
        self.layoutMode = layoutMode
        self.gridSettings = gridSettings
        self.pages = pages
        self.folders = folders
        self.itemOrder = itemOrder
        self.aliases = aliases
        self.hiddenApplicationIDs = hiddenApplicationIDs
        self.customSources = customSources
        self.triggerSettings = triggerSettings
        self.lastSelectedPage = lastSelectedPage
        self.lastScrollPosition = lastScrollPosition
        self.hideDockWhileLauncherOpen = hideDockWhileLauncherOpen
        self.dateAddedByID = dateAddedByID
        self.lastUsedByID = lastUsedByID
        self.appIconStyle = appIconStyle
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, layoutMode, gridSettings, pages, folders, itemOrder, aliases, hiddenApplicationIDs, customSources, triggerSettings, lastSelectedPage, lastScrollPosition, hideDockWhileLauncherOpen, dateAddedByID, lastUsedByID, appIconStyle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        layoutMode = try container.decode(LayoutMode.self, forKey: .layoutMode)
        gridSettings = try container.decode(GridSettings.self, forKey: .gridSettings)
        pages = try container.decode([[LayoutItem]].self, forKey: .pages)
        folders = try container.decode([FolderID: Folder].self, forKey: .folders)
        itemOrder = try container.decode([StableAppIdentifier].self, forKey: .itemOrder)
        aliases = try container.decode([StableAppIdentifier: String].self, forKey: .aliases)
        hiddenApplicationIDs = try container.decode(Set<StableAppIdentifier>.self, forKey: .hiddenApplicationIDs)
        customSources = try container.decode([CustomSourceConfig].self, forKey: .customSources)
        triggerSettings = try container.decode(TriggerSettings.self, forKey: .triggerSettings)
        lastSelectedPage = try container.decode(Int.self, forKey: .lastSelectedPage)
        lastScrollPosition = try container.decode(Double.self, forKey: .lastScrollPosition)
        hideDockWhileLauncherOpen = try container.decodeIfPresent(Bool.self, forKey: .hideDockWhileLauncherOpen) ?? false
        dateAddedByID = try container.decodeIfPresent([StableAppIdentifier: Date].self, forKey: .dateAddedByID) ?? [:]
        lastUsedByID = try container.decodeIfPresent([StableAppIdentifier: Date].self, forKey: .lastUsedByID) ?? [:]
        appIconStyle = try container.decodeIfPresent(AppIconStyle.self, forKey: .appIconStyle) ?? .classic
    }

    public static let currentSchemaVersion = 1

    public static let empty = LayoutDocument(
        schemaVersion: currentSchemaVersion,
        layoutMode: .paged,
        gridSettings: .default,
        pages: [[]],
        folders: [:],
        itemOrder: [],
        aliases: [:],
        hiddenApplicationIDs: [],
        customSources: [],
        triggerSettings: .default,
        lastSelectedPage: 0,
        lastScrollPosition: 0,
        hideDockWhileLauncherOpen: false,
        dateAddedByID: [:],
        lastUsedByID: [:],
        appIconStyle: .classic
    )
}
