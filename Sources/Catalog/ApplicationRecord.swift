import Foundation

/// One installed application, as discovered by `ApplicationScanner`.
/// Fields map directly to the "each record" list in the implementation plan.
public struct ApplicationRecord: Hashable, Codable, Sendable, Identifiable {
    public var id: StableAppID
    public var bundleIdentifier: String
    public var bundleURL: URL
    public var executableURL: URL?
    public var displayName: String
    public var originalDisplayName: String
    public var bundleVersion: String?
    public var teamIdentifier: String?
    public var category: String?
    public var sourceID: String
    public var isSystemProtected: Bool
    /// True when the bundle's own Info.plist declares itself as a background/
    /// menu-bar/agent app (`LSUIElement`/`LSBackgroundOnly`), i.e. not meant
    /// to appear as a regular launchable app. Distinct from the user-driven
    /// "hidden" feature (2.16), which is stored per-identity in
    /// `LayoutDocument.hiddenApplicationIDs`, not here.
    public var isBackgroundOnly: Bool
    public var iconCacheKey: String
    public var canLaunch: Bool
    public var canOpenNewInstance: Bool
    public var lastSeenModificationDate: Date

    public init(
        id: StableAppID,
        bundleIdentifier: String,
        bundleURL: URL,
        executableURL: URL?,
        displayName: String,
        originalDisplayName: String,
        bundleVersion: String?,
        teamIdentifier: String?,
        category: String?,
        sourceID: String,
        isSystemProtected: Bool,
        isBackgroundOnly: Bool,
        iconCacheKey: String,
        canLaunch: Bool,
        canOpenNewInstance: Bool,
        lastSeenModificationDate: Date
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.executableURL = executableURL
        self.displayName = displayName
        self.originalDisplayName = originalDisplayName
        self.bundleVersion = bundleVersion
        self.teamIdentifier = teamIdentifier
        self.category = category
        self.sourceID = sourceID
        self.isSystemProtected = isSystemProtected
        self.isBackgroundOnly = isBackgroundOnly
        self.iconCacheKey = iconCacheKey
        self.canLaunch = canLaunch
        self.canOpenNewInstance = canOpenNewInstance
        self.lastSeenModificationDate = lastSeenModificationDate
    }
}
