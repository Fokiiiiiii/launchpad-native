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

/// Populated in Phase 6 (Customization); present now so the schema doesn't
/// need a migration just to add it later.
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

    public static let `default` = GridSettings(
        columns: 7,
        rows: 5,
        iconSize: 96,
        horizontalSpacing: 24,
        verticalSpacing: 32,
        labelVisible: true,
        labelLineCount: 2,
        pageMargins: 48,
        folderGridSize: 9
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
public struct TriggerSettings: Codable, Sendable, Hashable {
    public var hotkeyEnabled: Bool
    public var hotkeyKeyCode: UInt16?
    public var hotkeyModifierFlags: UInt
    public var hotCornersEnabled: [String: Bool] // "topLeft"/"topRight"/"bottomLeft"/"bottomRight" -> enabled
    public var f4Enabled: Bool
    public var multitouchGestureEnabled: Bool
    public var multitouchSensitivity: Double

    // multitouchGestureEnabled defaults to true, and hotCornersEnabled
    // defaults with bottomRight on: real hands-on testing found that
    // relying on the 4-finger gesture alone left no *discoverable* trigger
    // for a first-time user — nobody finds a pinch gesture by accident the
    // way they'd notice a screen corner. bottomRight matches classic
    // Launchpad's own hot-corner convention. F4 needs Input Monitoring
    // permission this app bundle doesn't request yet; the hotkey needs a
    // key code, which the Settings UI now lets you record (see
    // HotkeyRecorderView) but still defaults to off until you set one.
    public static let `default` = TriggerSettings(
        hotkeyEnabled: false,
        hotkeyKeyCode: nil,
        hotkeyModifierFlags: 0,
        hotCornersEnabled: ["bottomRight": true],
        f4Enabled: true,
        multitouchGestureEnabled: true,
        multitouchSensitivity: 0.5
    )
}

/// The full persisted state of the launcher, versioned for migration.
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
        lastScrollPosition: 0
    )
}
