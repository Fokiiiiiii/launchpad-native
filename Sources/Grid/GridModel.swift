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

    /// Applies immediately (relayout) without losing item order — the grid
    /// only changes how many items fit per page, not which items exist.
    /// Reflows only when the *capacity itself* (`columns * rows`) actually
    /// changed, in either direction: shrinking needs it so overflow items
    /// don't render off the bottom of their page and vanish (see
    /// `loadDocument()`'s doc comment), growing needs it too (a real user
    /// report: increasing rows from 3 to 4 changed the layout but left
    /// pages grouped at the old, smaller capacity, so the newly-available
    /// row just sat empty).
    ///
    /// A prior version of this method reflowed *unconditionally*, on the
    /// mistaken assumption that reflowing at an unchanged capacity is a
    /// no-op. It isn't: `reflowPagesToCurrentCapacity()` flattens every
    /// page and repacks tightly to capacity, which silently destroyed any
    /// *intentionally non-compact* arrangement (pages the user left
    /// partially empty, gaps from manual drag-and-drop reordering) every
    /// single time any grid setting was applied — including changes
    /// completely unrelated to capacity, like icon size — a real regression
    /// confirmed via user report ("行数の設定やページごとのアプリ数の数が
    /// おかしい"). Comparing capacity before/after and only reflowing on an
    /// actual change avoids that.
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

    /// "カスタム" (manual drag order, unchanged), "名前順", "追加日順" (newest
    /// first), or "最終使用日順" (most recently launched first) — the latter
    /// two read from `LayoutDocument.dateAddedByID`/`lastUsedByID`, stamped
    /// by `reconcile(with:)`/`backfillMissingDateAdded()` and
    /// `recordLaunch(for:)` respectively.
    ///
    /// Sorts *within* each existing page/folder-page rather than flattening
    /// and repacking across them — page boundaries and folder membership
    /// are left exactly as they are, only the order within each container
    /// changes. Switching back to `.custom` is deliberately a no-op beyond
    /// recording the preference: the manual order was already overwritten
    /// by the last sort, so there's nothing to restore without tracking
    /// separate undo history, which isn't worth it for a toggle.
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

    /// Stamps "now" as this app's most recent launch — the basis for
    /// `SortMode.lastUsed`. Called from the single funnel point every
    /// launch path (grid click, search result, folder contents, "Open New
    /// Instance") ultimately goes through. Deliberately does *not* call
    /// `onChange?()`: `.lastUsed` is a one-shot sort applied when the user
    /// picks it in Settings (matching `.name`'s existing semantics, see
    /// this type's doc comment above), not a continuously-enforced live
    /// order — re-sorting the grid out from under someone at the exact
    /// moment they click an icon would be a surprising, distracting UI
    /// shuffle for no real benefit.
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

    /// Reconciles the live catalog against the persisted arrangement: apps no
    /// longer installed (or newly hidden) are pruned from pages/folders;
    /// newly discovered apps are appended in alphabetical order.
    ///
    /// - Parameter prunesMissingItems: whether `records` is authoritative
    ///   about what is installed. Real, confirmed data-corruption bug: the
    ///   startup path restores a cached catalog snapshot to get a first frame
    ///   up early, and that snapshot legitimately lags the real disk state
    ///   (observed live: 94 cached records restored, `Pruned 4 item(s) from
    ///   page 3` 6ms later, then `Full scan complete: 98 applications` 1.6s
    ///   later). Treating that partial set as authoritative deleted the four
    ///   apps it hadn't cached yet, and the completed scan then re-appended
    ///   them as "new" at the end of the grid — silently reshuffling the
    ///   user's last page on *every* launch, with the exact order depending on
    ///   which records the snapshot happened to hold. A cached snapshot can
    ///   only ever add confidence that an app exists, never that one is gone,
    ///   so removal stays gated on a completed scan.
    @discardableResult
    public func reconcile(with records: [ApplicationRecord], prunesMissingItems: Bool = true) -> Bool {
        let previousRecords = recordsByIDValue
        let previousPages = pages
        let previousFolders = folders
        let previousItemOrder = document.itemOrder
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
            || previousItemOrder != document.itemOrder
            || previousDateAdded != document.dateAddedByID
        if changed {
            onChange?()
        }
        return changed
    }

    /// Apps placed before `dateAddedByID` existed (i.e. every app already in
    /// a real user's grid the first time they launch a build with this
    /// feature) have no recorded timestamp. Rather than leaving them all
    /// tied at "unknown" — which would make `SortMode.dateAdded` fall back
    /// to an arbitrary order for someone's *entire* existing grid — backfill
    /// each with a synthetic, strictly-increasing timestamp based on its
    /// current position: apps get appended to the end of the grid over time
    /// (see `appendToLastPage`), so existing position is the best available
    /// proxy for "roughly when this was added" without inventing history
    /// this app never actually recorded. Anchored to the Unix epoch (not
    /// "now minus N seconds") so backfilled values always sort older than
    /// genuinely-new `Date()` timestamps stamped going forward, regardless
    /// of when this backfill happens to run. Only fills gaps — once an item
    /// has an entry, this is a no-op for it on every subsequent reconcile.
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

    /// Removes items no longer found in the current catalog scan from both
    /// pages and folders. Folders that become empty as a result are
    /// dissolved (reusing `isFolderEmpty`/`dissolveFolder`, the same pair
    /// `removeFromFolder` already uses for the user-driven single-item
    /// case) — a real bug had this path leave behind empty, named folder
    /// shells (confirmed on a real `layout.json`: "その他"/"ゲーム", legacy-
    /// imported with real contents per project history, both later found
    /// with 0 items but their folder entries still present) because only
    /// the user-driven removal path used to check for the resulting empty
    /// state.
    ///
    /// Every identifier actually pruned is logged — root-caused why
    /// specific apps stop matching `validIDs` between scans wasn't possible
    /// from this session's read-only investigation (code-signing team ID
    /// and path were both confirmed stable via `codesign` for the affected
    /// apps), so if this recurs, `DiagnosticsLog.grid` is where to look
    /// next time instead of reverse-engineering it after the fact. This
    /// path prunes top-level page items with the exact same `validIDs`
    /// check, so a recurrence could in principle affect ordinary grid items
    /// too, not just folder contents — the logging covers both.
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

    /// Real, confirmed report ("フォルダ内だとアプリの並び替えができな
    /// い"): the folder-internal equivalent of `moveItem` above — same
    /// remove/clamp/insert shape, but scoped to one page inside a single
    /// folder's own `pages` array, driven by `FolderOverlayTileView`'s
    /// SwiftUI `.draggable`/`.dropDestination` (not the main grid's
    /// AppKit-only `ItemDragSession`, which has no way to address a
    /// folder's internal contents). Deliberately doesn't span folder pages
    /// — `FolderContentsViewController` flattens all of a folder's pages
    /// into one scrollable list for display, but the underlying model
    /// still pages at `gridSettings.folderGridSize`; letting a drag reorder
    /// across that boundary would need to decide how the two pages'
    /// capacities absorb the move, which the caller isn't set up to
    /// resolve yet (see `FolderContentsViewController.reorderTile`'s own
    /// same-page guard).
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
    /// `appendToFolder` above is the only place that has ever enforced that
    /// capacity, and two paths get around it: `createOrJoinFolder` builds a
    /// two-item folder directly, and `LegacyLaunchpadImporter` puts *every*
    /// imported item on one page regardless of count. `removeFromFolder`
    /// separately leaves a hole in a middle page rather than compacting.
    ///
    /// None of that was visible while the opened folder flattened all of its
    /// pages into one scrolling list — it only matters now that a page is
    /// something the user actually sees and swipes between. Returns whether
    /// anything moved, so a caller can decide whether a save is warranted.
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

    /// User-invoked "Ungroup" — unlike the private `dissolveFolder`/
    /// `isFolderEmpty` pair above (which only ever fire automatically once a
    /// folder has *already* emptied via pruning or a drag-out), this
    /// dissolves a folder that still has real contents. Flattens the
    /// folder's internal pages in their existing order and splices them into
    /// `pages` at exactly the folder's former position — contiguous,
    /// matching a real Springboard/Launchpad ungroup. Reuses
    /// `reflowPagesToCurrentCapacity()` for the overflow case (splicing N
    /// items in place of 1 can push a page over `capacityPerPage`) rather
    /// than a bespoke overflow routine.
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
