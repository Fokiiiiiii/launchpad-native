import Catalog
import Diagnostics
import Foundation
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

    /// Fired specifically when the hidden-app set changes. LauncherWindowController
    /// uses this narrower signal to refresh the searchable snapshot immediately
    /// after a context-menu hide/unhide, without coupling GridModel to search UI.
    public var onHiddenApplicationsChange: (() -> Void)?

    public init(layoutStore: LayoutStore) {
        self.layoutStore = layoutStore
    }

    public func loadDocument() async {
        document = await layoutStore.load()
        pages = document.pages.isEmpty ? [[]] : document.pages
        folders = document.folders

        // Vertical scrolling is a legacy value without a renderer. Normalize it
        // in memory and persist the migration together with any capacity reflow.
        var requiresSave = false
        if document.layoutMode == .verticalScroll {
            document.layoutMode = .paged
            requiresSave = true
        }

        gridSettings = document.gridSettings
        // A document can contain pages packed for a larger capacity. Reflow
        // once when needed, then save the healed arrangement so subsequent
        // launches do not repeat the repair.
        if pages.contains(where: { $0.count > capacityPerPage }) {
            reflowPagesToCurrentCapacity()
            requiresSave = true
        }
        // Same repair, one level down: a folder can hold pages packed past
        // `folderGridSize` (legacy import puts everything on one page) or with
        // a hole punched in a middle page by a drag-out. Heal once and persist,
        // so later launches do not redo it.
        if normalizeFolderPages() {
            requiresSave = true
        }

        if requiresSave {
            await save()
        }
    }

    public var triggerSettings: TriggerSettings {
        document.triggerSettings
    }

    public func updateTriggerSettings(_ settings: TriggerSettings) {
        document.triggerSettings = settings
    }

    /// Reflows only when capacity (`columns * rows`) actually changed, either
    /// way: shrinking hides overflow items off the page, growing leaves the new
    /// row empty. Reflowing *unconditionally* is not a no-op — it repacks every
    /// page tightly, destroying gaps the user arranged on purpose, on every
    /// unrelated settings change ("行数の設定やページごとのアプリ数がおかしい").
    public func updateGridSettings(_ settings: GridSettings) {
        let oldCapacity = capacityPerPage
        gridSettings = settings
        document.gridSettings = settings
        if capacityPerPage != oldCapacity {
            reflowPagesToCurrentCapacity()
        }
        onChange?()
    }

    /// Regroups `pages` into chunks of exactly `capacityPerPage` (the last
    /// chunk may be smaller), preserving overall item order. Called
    /// automatically whenever capacity actually changes (see
    /// `updateGridSettings`), and exposed publicly as the Settings
    /// "Reorganize" button for a user who wants pages tightly repacked
    /// under the *current*, unchanged grid settings — e.g. after manually
    /// dragging gaps into pages over time.
    public func reorganizePages() {
        reflowPagesToCurrentCapacity()
        onChange?()
    }

    private func reflowPagesToCurrentCapacity() {
        let capacity = capacityPerPage
        let flattened = pages.flatMap { $0 }
        guard !flattened.isEmpty else { return }
        var newPages: [[LayoutItem]] = []
        var index = flattened.startIndex
        while index < flattened.endIndex {
            let end = min(index + capacity, flattened.endIndex)
            newPages.append(Array(flattened[index..<end]))
            index = end
        }
        pages = newPages
    }

    public var layoutMode: LayoutMode {
        document.layoutMode
    }

    public func setLayoutMode(_ mode: LayoutMode) {
        document.layoutMode = mode
        onChange?()
    }

    public var hideDockWhileLauncherOpen: Bool {
        document.hideDockWhileLauncherOpen
    }

    public func setHideDockWhileLauncherOpen(_ value: Bool) {
        document.hideDockWhileLauncherOpen = value
        onChange?()
    }

    public var appIconStyle: AppIconStyle {
        document.appIconStyle
    }

    public func setAppIconStyle(_ style: AppIconStyle) {
        document.appIconStyle = style
        onChange?()
    }

    public var showsMenuBarIcon: Bool {
        document.showsMenuBarIcon
    }

    public func setShowsMenuBarIcon(_ value: Bool) {
        document.showsMenuBarIcon = value
        onChange?()
    }

    /// Whether LSUIElement (menu-bar) apps may be placed on the grid and
    /// offered to launcher search. LSBackgroundOnly is always excluded by
    /// `isEligibleForGrid(_:)`, regardless of this setting.
    public var showMenuBarApplications: Bool {
        document.showMenuBarApplications
    }

    public func setShowMenuBarApplications(_ value: Bool) {
        guard document.showMenuBarApplications != value else { return }
        document.showMenuBarApplications = value
        // Reconcile the existing catalog immediately so the setting has live
        // effect: disabling removes menu-bar apps from the layout, while
        // enabling discovers them again using the normal placement policy.
        if !recordsByIDValue.isEmpty {
            reconcile(with: allRecords)
        } else {
            onChange?()
        }
    }

    public var showsHiddenAppsInSearch: Bool {
        document.showsHiddenAppsInSearch
    }

    public func setShowsHiddenAppsInSearch(_ value: Bool) {
        document.showsHiddenAppsInSearch = value
        onChange?()
    }

    public var backgroundMode: LauncherBackgroundMode {
        document.backgroundMode
    }

    public func setBackgroundMode(_ mode: LauncherBackgroundMode) {
        document.backgroundMode = mode
    }

    public var glassMaterialIntensity: Double {
        document.glassMaterialIntensity
    }

    public func setGlassMaterialIntensity(_ value: Double) {
        document.glassMaterialIntensity = min(max(value, 0), 1)
    }

    public var blursWallpaper: Bool {
        document.blursWallpaper
    }

    public func setBlursWallpaper(_ value: Bool) {
        document.blursWallpaper = value
    }

    /// Sorts *within* each page and folder page — boundaries and folder
    /// membership are untouched, only the order inside each container changes.
    /// `.dateAdded`/`.lastUsed` read `LayoutDocument`'s stamped timestamps.
    /// Switching back to `.custom` is a no-op beyond recording the preference:
    /// the manual order was already overwritten, and restoring it would need
    /// undo history this does not keep.
    public func applySortMode(_ mode: SortMode) {
        gridSettings.sortMode = mode
        document.gridSettings = gridSettings
        switch mode {
        case .custom:
            break
        case .name:
            sortEachContainer(by: isOrderedByLabel)
        case .dateAdded:
            sortEachContainer(by: isOrderedByDateAddedNewestFirst)
        case .lastUsed:
            sortEachContainer(by: isOrderedByLastUsedMostRecentFirst)
        }
        onChange?()
    }

    private func sortEachContainer(by areInIncreasingOrder: (LayoutItem, LayoutItem) -> Bool) {
        for pageIndex in pages.indices {
            pages[pageIndex].sort(by: areInIncreasingOrder)
        }
        for folderID in Array(folders.keys) {
            guard var folder = folders[folderID] else { continue }
            for pageIndex in folder.pages.indices {
                folder.pages[pageIndex].sort(by: areInIncreasingOrder)
            }
            folders[folderID] = folder
        }
    }

    private func isOrderedByLabel(_ lhs: LayoutItem, _ rhs: LayoutItem) -> Bool {
        effectiveLabel(for: lhs).localizedCaseInsensitiveCompare(effectiveLabel(for: rhs)) == .orderedAscending
    }

    private func effectiveLabel(for item: LayoutItem) -> String {
        switch item {
        case .app(let identifier):
            guard let record = recordsByIDValue[identifier.value] else { return "" }
            return displayName(for: record)
        case .folder(let folderID):
            return folders[folderID]?.name ?? ""
        }
    }

    /// Folders have no `dateAdded`/`lastUsed` timestamp of their own (they're
    /// created by joining existing apps, not "added" the way an app is) —
    /// `.distantPast` sorts them to the end under both "newest/most-recent
    /// first" comparators below, alongside any app that's never been
    /// launched or predates this feature and hasn't been backfilled yet.
    /// Swift's `sort(by:)` is a stable sort, so ties (all the `.distantPast`
    /// items) keep their existing relative order rather than shuffling.
    private func isOrderedByDateAddedNewestFirst(_ lhs: LayoutItem, _ rhs: LayoutItem) -> Bool {
        dateAdded(for: lhs) > dateAdded(for: rhs)
    }

    private func isOrderedByLastUsedMostRecentFirst(_ lhs: LayoutItem, _ rhs: LayoutItem) -> Bool {
        lastUsed(for: lhs) > lastUsed(for: rhs)
    }

    private func dateAdded(for item: LayoutItem) -> Date {
        guard case .app(let identifier) = item else { return .distantPast }
        return document.dateAddedByID[identifier] ?? .distantPast
    }

    private func lastUsed(for item: LayoutItem) -> Date {
        guard case .app(let identifier) = item else { return .distantPast }
        return document.lastUsedByID[identifier] ?? .distantPast
    }

    /// Stamps "now" as this app's most recent launch, from the single funnel
    /// every launch path goes through. Deliberately does not fire `onChange`:
    /// `.lastUsed` is a one-shot sort applied when picked in Settings, not a
    /// live order — reshuffling the grid as someone clicks would be startling.
    public func recordLaunch(for id: StableAppID) {
        document.lastUsedByID[id.asPersistenceIdentifier] = Date()
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

    /// Returns catalog records in the same order the user sees them in the
    /// grid: page order, then folder position, then any not-yet-placed records.
    /// Search uses this instead of inventing a second alphabetical order.
    public func orderedRecords(from records: [ApplicationRecord]) -> [ApplicationRecord] {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id.value, $0) })
        var orderedIDs: [String] = []
        var seen = Set<String>()

        func append(_ id: StableAppIdentifier) {
            guard seen.insert(id.value).inserted else { return }
            orderedIDs.append(id.value)
        }

        for page in pages {
            for item in page {
                switch item {
                case .app(let id):
                    append(id)
                case .folder(let folderID):
                    for folderPage in folders[folderID]?.pages ?? [] {
                        for folderItem in folderPage {
                            if case .app(let id) = folderItem { append(id) }
                        }
                    }
                }
            }
        }

        let placed = orderedIDs.compactMap { recordsByID[$0] }
        return placed + records.filter { seen.insert($0.id.value).inserted }
    }

    /// Reconciles the live catalog against the persisted arrangement: apps no
    /// longer installed (or newly hidden) are pruned; new ones are appended
    /// alphabetically.
    ///
    /// - Parameter prunesMissingItems: whether `records` is authoritative about
    ///   what is installed. The startup path restores a cached snapshot that
    ///   legitimately lags the disk (observed: 94 cached, 4 pruned 6ms later,
    ///   98 found 1.6s later). Treating that as authoritative deleted the four
    ///   it had not cached, and the full scan re-appended them as new.
    @discardableResult
    public func reconcile(with records: [ApplicationRecord], prunesMissingItems: Bool = true) -> Bool {
        let previousRecords = recordsByIDValue
        let previousPages = pages
        let previousFolders = folders
        let previousDateAdded = document.dateAddedByID

        recordsByIDValue = Dictionary(uniqueKeysWithValues: records.map { ($0.id.value, $0) })
        let hiddenIDs = Set(document.hiddenApplicationIDs.map(\.value))
        let validIDs = Set(recordsByIDValue.values.filter(isEligibleForGrid(_:)).map { $0.id.value })
            .subtracting(hiddenIDs)

        if prunesMissingItems {
            pruneMissingItems(validIDs: validIDs)
        }
        backfillMissingDateAdded()

        let placedIDs = allPlacedAppIdentifierValues()
        let newRecords = records
            .filter(isEligibleForGrid(_:))
            .filter { !hiddenIDs.contains($0.id.value) }
            .filter { !placedIDs.contains($0.id.value) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        for record in newRecords {
            let identifier = record.id.asPersistenceIdentifier
            appendToLastPage(.app(identifier))
            document.dateAddedByID[identifier] = Date()
        }

        let changed = previousRecords != recordsByIDValue
            || previousPages != pages
            || previousFolders != folders
            || previousDateAdded != document.dateAddedByID
        if changed {
            onChange?()
        }
        return changed
    }

    /// Apps that predate `dateAddedByID` have no timestamp, which would leave
    /// `SortMode.dateAdded` arbitrary across someone's entire existing grid.
    /// Each is backfilled from its current position — apps are appended over
    /// time, so position is the best available proxy. Anchored to the epoch so
    /// backfilled values always sort older than genuinely new ones.
    private func backfillMissingDateAdded() {
        var index = 0
        for page in pages {
            for item in page {
                guard case .app(let id) = item, document.dateAddedByID[id] == nil else { continue }
                document.dateAddedByID[id] = Date(timeIntervalSince1970: TimeInterval(index))
                index += 1
            }
        }
        for folderID in folders.keys.sorted(by: { $0.value < $1.value }) {
            guard let folder = folders[folderID] else { continue }
            for folderPage in folder.pages {
                for item in folderPage {
                    guard case .app(let id) = item, document.dateAddedByID[id] == nil else { continue }
                    document.dateAddedByID[id] = Date(timeIntervalSince1970: TimeInterval(index))
                    index += 1
                }
            }
        }
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

    /// Removes items no longer in the catalog from pages and folders, and
    /// dissolves folders left empty (reusing the same pair `removeFromFolder`
    /// uses). Without that last step this path left empty named folder shells
    /// behind, since only the user-driven removal checked for it.
    ///
    /// Every pruned identifier is logged: why specific apps stop matching
    /// between scans has never been root-caused.
    private func pruneMissingItems(validIDs: Set<String>) {
        for pageIndex in pages.indices {
            let before = pages[pageIndex]
            pages[pageIndex] = before.filter { item in
                guard case .app(let id) = item else { return true }
                return validIDs.contains(id.value)
            }
            let removed = before.count - pages[pageIndex].count
            if removed > 0 {
                let removedIDs = before.compactMap { item -> String? in
                    guard case .app(let id) = item, !validIDs.contains(id.value) else { return nil }
                    return id.value
                }
                DiagnosticsLog.grid.notice("Pruned \(removed, privacy: .public) item(s) from page \(pageIndex, privacy: .public): \(removedIDs, privacy: .private)")
            }
        }
        for folderID in Array(folders.keys) {
            guard var folder = folders[folderID] else { continue }
            var prunedFromFolder = 0
            var removedFromFolder: [String] = []
            folder.pages = folder.pages.map { folderPage in
                folderPage.filter { item in
                    guard case .app(let id) = item else { return true }
                    let isValid = validIDs.contains(id.value)
                    if !isValid {
                        prunedFromFolder += 1
                        removedFromFolder.append(id.value)
                    }
                    return isValid
                }
            }
            folders[folderID] = folder
            if prunedFromFolder > 0 {
                DiagnosticsLog.grid.notice("Pruned \(prunedFromFolder, privacy: .public) item(s) from folder \"\(folder.name, privacy: .public)\": \(removedFromFolder, privacy: .private)")
            }
            if isFolderEmpty(folderID) {
                DiagnosticsLog.grid.notice("Folder \"\(folder.name, privacy: .public)\" is empty after pruning — dissolving")
                dissolveFolder(folderID)
            }
        }
    }

    private var capacityPerPage: Int { max(gridSettings.columns * gridSettings.rows, 1) }

    /// The single grid-placement policy. `LSBackgroundOnly` is always
    /// excluded; `LSUIElement` records are controlled by the persisted
    /// `showMenuBarApplications` setting.
    private func isEligibleForGrid(_ record: ApplicationRecord) -> Bool {
        !record.isBackgroundOnly && (showMenuBarApplications || !record.isMenuBarApp)
    }

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

    /// The folder-internal equivalent of `moveItem`, scoped to one page inside
    /// one folder. Deliberately does not span folder pages: that would need a
    /// decision about how the two pages' capacities absorb the move, which the
    /// caller is not set up to resolve.
    public func moveItemWithinFolder(_ folderID: FolderID, page: Int, fromIndex: Int, toIndex: Int) {
        guard var folder = folders[folderID],
              folder.pages.indices.contains(page),
              folder.pages[page].indices.contains(fromIndex),
              fromIndex != toIndex else { return }
        let item = folder.pages[page].remove(at: fromIndex)
        let clampedIndex = min(max(toIndex, 0), folder.pages[page].count)
        folder.pages[page].insert(item, at: clampedIndex)
        folders[folderID] = folder
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
            // Built through the same capacity path as every other insertion
            // rather than assigning a page literal, so there is one rule for
            // how many items a folder page may hold.
            var folder = Folder(name: defaultFolderName, pages: [[]])
            appendToFolder(&folder, item: targetItem)
            appendToFolder(&folder, item: draggedItem)
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

    /// Repacks a folder's pages into chunks of exactly `capacity`, preserving
    /// the order items appear in. The folder equivalent of
    /// `reflowPagesToCurrentCapacity`, kept pure so the packing itself can be
    /// tested without a model.
    ///
    /// A folder whose pages are already correctly packed comes back unchanged,
    /// including an empty folder (`[[]]`), so callers can apply this
    /// unconditionally.
    nonisolated static func folderPagesRepacked(_ pages: [[LayoutItem]], capacity: Int) -> [[LayoutItem]] {
        let capacity = max(capacity, 1)
        let flattened = pages.flatMap { $0 }
        guard !flattened.isEmpty else { return [[]] }
        var repacked: [[LayoutItem]] = []
        var index = flattened.startIndex
        while index < flattened.endIndex {
            let end = min(index + capacity, flattened.endIndex)
            repacked.append(Array(flattened[index..<end]))
            index = end
        }
        return repacked
    }

    /// Brings every folder's pages back in line with `folderGridSize`.
    ///
    /// `appendToFolder` is the only place that enforces it, and two paths got
    /// around it: `createOrJoinFolder` built a two-item page directly, and the
    /// legacy importer put every item on one page. `removeFromFolder` left
    /// holes. None of it showed while the UI flattened folders into one list.
    /// Returns whether anything moved, so the caller can decide to save.
    @discardableResult
    public func normalizeFolderPages() -> Bool {
        var changed = false
        for (id, folder) in folders {
            let repacked = Self.folderPagesRepacked(folder.pages, capacity: gridSettings.folderGridSize)
            guard repacked != folder.pages else { continue }
            folders[id]?.pages = repacked
            changed = true
        }
        return changed
    }

    public func removeFromFolder(_ folderID: FolderID, folderPage: Int, folderIndex: Int, toPage: Int) {
        guard var folder = folders[folderID],
              folder.pages.indices.contains(folderPage),
              folder.pages[folderPage].indices.contains(folderIndex) else { return }
        let item = folder.pages[folderPage].remove(at: folderIndex)
        // Compact rather than leaving a hole in a middle page — a gap the user
        // can now see and swipe past.
        folder.pages = Self.folderPagesRepacked(folder.pages, capacity: gridSettings.folderGridSize)
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

    /// User-invoked "Ungroup": dissolves a folder that still has contents,
    /// unlike the automatic `dissolveFolder` for ones already emptied. Splices
    /// the folder's items into `pages` at its former position, contiguous, and
    /// reuses the normal reflow for the overflow that can cause.
    public func ungroupFolder(_ id: FolderID) {
        guard let folder = folders[id] else { return }
        let flattenedItems = folder.pages.flatMap { $0 }

        outer: for pageIndex in pages.indices {
            for (itemIndex, item) in pages[pageIndex].enumerated() {
                if case .folder(let folderID) = item, folderID == id {
                    pages[pageIndex].remove(at: itemIndex)
                    pages[pageIndex].insert(contentsOf: flattenedItems, at: itemIndex)
                    break outer
                }
            }
        }
        folders.removeValue(forKey: id)

        if pages.contains(where: { $0.count > capacityPerPage }) {
            reflowPagesToCurrentCapacity()
        }
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
        onHiddenApplicationsChange?()
    }

    public func unhideApplication(_ identifier: StableAppIdentifier) {
        document.hiddenApplicationIDs.remove(identifier)
        if recordsByIDValue[identifier.value] != nil, !allPlacedAppIdentifierValues().contains(identifier.value) {
            appendToLastPage(.app(identifier))
        }
        onChange?()
        onHiddenApplicationsChange?()
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

    @discardableResult
    public func save() async -> Bool {
        document.pages = pages
        document.folders = folders
        do {
            try await layoutStore.save(document)
            return true
        } catch {
            DiagnosticsLog.persistence.error("Failed to save layout: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Saves through the same actor-backed store but returns the outcome to a
    /// caller that is coordinating an external transaction.
    @discardableResult
    public func saveResult() async -> Bool {
        document.pages = pages
        document.folders = folders
        return await layoutStore.saveResult(document)
    }
}
