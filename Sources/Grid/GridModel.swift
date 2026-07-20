import Catalog
import Diagnostics
import Persistence

/// The composition layer between `Catalog` (what's installed) and
/// `Persistence` (how the user arranged it): owns the live pages/folders,
/// reconciles them against catalog changes (new apps get appended, removed
/// apps get pruned), and is the single place mutation operations (reorder,
/// folder create/rename/dissolve) happen before being persisted.
@MainActor
public final class GridModel {
    public private(set) var pages: [[LayoutItem]] = [[]]
    public private(set) var folders: [FolderID: Folder] = [:]
    public private(set) var gridSettings: GridSettings = .default
    private var recordsByIDValue: [String: ApplicationRecord] = [:]
    private var document: LayoutDocument = .empty

    private let layoutStore: LayoutStore

    /// Fired after any mutation (reconcile, reorder, folder ops) so a view
    /// controller can reload without this model knowing about NSCollectionView.
    public var onChange: (() -> Void)?

    public init(layoutStore: LayoutStore) {
        self.layoutStore = layoutStore
    }

    public func loadDocument() async {
        document = await layoutStore.load()
        pages = document.pages.isEmpty ? [[]] : document.pages
        folders = document.folders
        gridSettings = document.gridSettings
    }

    public var triggerSettings: TriggerSettings {
        document.triggerSettings
    }

    public func updateTriggerSettings(_ settings: TriggerSettings) {
        document.triggerSettings = settings
    }

    /// Applies immediately (relayout) without losing item order — the grid
    /// only changes how many items fit per page, not which items exist.
    public func updateGridSettings(_ settings: GridSettings) {
        gridSettings = settings
        document.gridSettings = settings
        onChange?()
    }

    public var layoutMode: LayoutMode {
        document.layoutMode
    }

    public func setLayoutMode(_ mode: LayoutMode) {
        document.layoutMode = mode
        onChange?()
    }

    public func record(for identifier: StableAppIdentifier) -> ApplicationRecord? {
        recordsByIDValue[identifier.value]
    }

    public func record(for id: StableAppID) -> ApplicationRecord? {
        recordsByIDValue[id.value]
    }

    /// Every app currently known to the catalog, regardless of hidden state
    /// or placement — used by surfaces (e.g. the Uninstall picker) that need
    /// the full set, not just what's on a grid page.
    public var allRecords: [ApplicationRecord] {
        Array(recordsByIDValue.values)
    }

    /// Reconciles the live catalog against the persisted arrangement: apps no
    /// longer installed (or newly hidden) are pruned from pages/folders;
    /// newly discovered apps are appended in alphabetical order.
    public func reconcile(with records: [ApplicationRecord]) {
        recordsByIDValue = Dictionary(uniqueKeysWithValues: records.map { ($0.id.value, $0) })
        let hiddenIDs = Set(document.hiddenApplicationIDs.map(\.value))
        let validIDs = Set(recordsByIDValue.keys).subtracting(hiddenIDs)

        pruneMissingItems(validIDs: validIDs)

        let placedIDs = allPlacedAppIdentifierValues()
        let newRecords = records
            .filter { !$0.isBackgroundOnly }
            .filter { !hiddenIDs.contains($0.id.value) }
            .filter { !placedIDs.contains($0.id.value) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        for record in newRecords {
            appendToLastPage(.app(record.id.asPersistenceIdentifier))
        }
        onChange?()
    }

    private func allPlacedAppIdentifierValues() -> Set<String> {
        var result = Set<String>()
        for page in pages {
            for item in page {
                switch item {
                case .app(let id):
                    result.insert(id.value)
                case .folder(let folderID):
                    guard let folder = folders[folderID] else { continue }
                    for folderPage in folder.pages {
                        for folderItem in folderPage {
                            if case .app(let id) = folderItem { result.insert(id.value) }
                        }
                    }
                }
            }
        }
        return result
    }

    private func pruneMissingItems(validIDs: Set<String>) {
        for pageIndex in pages.indices {
            pages[pageIndex] = pages[pageIndex].filter { item in
                guard case .app(let id) = item else { return true }
                return validIDs.contains(id.value)
            }
        }
        for folderID in Array(folders.keys) {
            guard var folder = folders[folderID] else { continue }
            folder.pages = folder.pages.map { folderPage in
                folderPage.filter { item in
                    guard case .app(let id) = item else { return true }
                    return validIDs.contains(id.value)
                }
            }
            folders[folderID] = folder
        }
    }

    private var capacityPerPage: Int { max(gridSettings.columns * gridSettings.rows, 1) }

    private func appendToLastPage(_ item: LayoutItem) {
        if pages.isEmpty { pages.append([]) }
        if pages[pages.count - 1].count >= capacityPerPage {
            pages.append([item])
        } else {
            pages[pages.count - 1].append(item)
        }
    }

    // MARK: - Mutations

    public func moveItem(fromPage: Int, fromIndex: Int, toPage: Int, toIndex: Int) {
        guard pages.indices.contains(fromPage), pages[fromPage].indices.contains(fromIndex) else { return }
        let item = pages[fromPage].remove(at: fromIndex)
        while pages.count <= toPage { pages.append([]) }
        let clampedIndex = min(max(toIndex, 0), pages[toPage].count)
        pages[toPage].insert(item, at: clampedIndex)
        onChange?()
    }

    /// Dragging one item onto another: onto a bare app, both merge into a new
    /// folder; onto an existing folder, the dragged item joins it.
    public func createOrJoinFolder(sourcePage: Int, sourceIndex: Int, destinationPage: Int, destinationIndex: Int, defaultFolderName: String = "New Folder") {
        guard pages.indices.contains(sourcePage), pages[sourcePage].indices.contains(sourceIndex),
              pages.indices.contains(destinationPage), pages[destinationPage].indices.contains(destinationIndex),
              !(sourcePage == destinationPage && sourceIndex == destinationIndex) else { return }

        let draggedItem = pages[sourcePage][sourceIndex]
        let targetItem = pages[destinationPage][destinationIndex]

        switch targetItem {
        case .app:
            let folder = Folder(name: defaultFolderName, pages: [[targetItem, draggedItem]])
            folders[folder.id] = folder
            pages[destinationPage][destinationIndex] = .folder(folder.id)
            pages[sourcePage].remove(at: sourceIndex)
        case .folder(let folderID):
            guard var folder = folders[folderID] else { return }
            appendToFolder(&folder, item: draggedItem)
            folders[folderID] = folder
            pages[sourcePage].remove(at: sourceIndex)
        }
        onChange?()
    }

    private func appendToFolder(_ folder: inout Folder, item: LayoutItem) {
        if folder.pages.isEmpty { folder.pages = [[]] }
        if folder.pages[folder.pages.count - 1].count >= gridSettings.folderGridSize {
            folder.pages.append([item])
        } else {
            folder.pages[folder.pages.count - 1].append(item)
        }
    }

    public func removeFromFolder(_ folderID: FolderID, folderPage: Int, folderIndex: Int, toPage: Int) {
        guard var folder = folders[folderID],
              folder.pages.indices.contains(folderPage),
              folder.pages[folderPage].indices.contains(folderIndex) else { return }
        let item = folder.pages[folderPage].remove(at: folderIndex)
        folders[folderID] = folder

        while pages.count <= toPage { pages.append([]) }
        pages[toPage].append(item)

        if isFolderEmpty(folderID) {
            dissolveFolder(folderID)
        }
        onChange?()
    }

    private func isFolderEmpty(_ id: FolderID) -> Bool {
        folders[id]?.pages.allSatisfy(\.isEmpty) ?? true
    }

    private func dissolveFolder(_ id: FolderID) {
        folders.removeValue(forKey: id)
        for pageIndex in pages.indices {
            pages[pageIndex].removeAll {
                if case .folder(let folderID) = $0 { return folderID == id }
                return false
            }
        }
    }

    public func renameFolder(_ id: FolderID, to name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        folders[id]?.name = name
        onChange?()
    }

    // MARK: - Hidden apps (2.16)

    /// Hides without unregistering/deleting anything — the app stays
    /// installed and known to Catalog, it just drops out of pages/folders
    /// and normal search until unhidden.
    public func hideApplication(_ id: StableAppID) {
        let identifier = id.asPersistenceIdentifier
        document.hiddenApplicationIDs.insert(identifier)
        let hiddenValues = Set(document.hiddenApplicationIDs.map(\.value))
        let validIDs = Set(recordsByIDValue.keys).subtracting(hiddenValues)
        pruneMissingItems(validIDs: validIDs)
        onChange?()
    }

    public func unhideApplication(_ identifier: StableAppIdentifier) {
        document.hiddenApplicationIDs.remove(identifier)
        if recordsByIDValue[identifier.value] != nil, !allPlacedAppIdentifierValues().contains(identifier.value) {
            appendToLastPage(.app(identifier))
        }
        onChange?()
    }

    public var hiddenApplicationIdentifiers: [StableAppIdentifier] {
        Array(document.hiddenApplicationIDs)
    }

    // MARK: - Display name aliasing (2.15)

    /// Overrides display name only for this app — never touches the bundle
    /// or Info.plist. Passing `nil` (or blank) clears the alias.
    public func setAlias(_ alias: String?, for id: StableAppID) {
        let identifier = id.asPersistenceIdentifier
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            document.aliases[identifier] = trimmed
        } else {
            document.aliases.removeValue(forKey: identifier)
        }
        onChange?()
    }

    public func alias(for id: StableAppID) -> String? {
        document.aliases[id.asPersistenceIdentifier]
    }

    /// The name to actually display: alias if set, else the catalog name.
    public func displayName(for record: ApplicationRecord) -> String {
        alias(for: record.id) ?? record.displayName
    }

    // MARK: - Custom sources (2.13)

    public var customSources: [CustomSourceConfig] {
        document.customSources
    }

    public func addCustomSource(_ config: CustomSourceConfig) {
        guard !document.customSources.contains(where: { $0.id == config.id }) else { return }
        document.customSources.append(config)
        onChange?()
    }

    public func removeCustomSource(id: String) {
        document.customSources.removeAll { $0.id == id }
        onChange?()
    }

    public func setCustomSourceEnabled(id: String, enabled: Bool) {
        guard let index = document.customSources.firstIndex(where: { $0.id == id }) else { return }
        document.customSources[index].enabled = enabled
        onChange?()
    }

    // MARK: - Legacy import

    /// Applies a one-time Classic Launchpad import, but only when this
    /// app's own layout is still completely empty (no pages, no folders) —
    /// i.e. first run, before the user has arranged anything here. Safe to
    /// call on every launch; it's a no-op once real state exists.
    @discardableResult
    public func applyLegacyImportIfFirstRun(_ result: LegacyImportResult) -> Bool {
        let hasExistingArrangement = folders.isEmpty == false || pages.contains { !$0.isEmpty }
        guard !hasExistingArrangement else { return false }

        for folder in result.folders {
            folders[folder.id] = folder
        }
        pages = [[]]
        // `unplacedAppOrder` already has folder placeholders interleaved at
        // their original relative position (see LegacyLaunchpadImporter).
        for item in result.unplacedAppOrder {
            appendToLastPage(item)
        }
        onChange?()
        return true
    }

    // MARK: - Persistence

    public func save() async {
        document.pages = pages
        document.folders = folders
        do {
            try await layoutStore.save(document)
        } catch {
            DiagnosticsLog.persistence.error("Failed to save layout: \(String(describing: error), privacy: .public)")
        }
    }
}
