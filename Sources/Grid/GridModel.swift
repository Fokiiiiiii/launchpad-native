import Catalog
import Diagnostics
import Foundation
import Localization
import Persistence

/// The composition layer between `Catalog` (what's installed) and
/// `Persistence` (how the user arranged it): owns the live pages/folders,
/// reconciles them against catalog changes (new apps get appended, removed
/// apps get pruned), and is the single place mutation operations (reorder,
/// folder create/rename/dissolve) happen before being persisted.

import CLaunchpadCore

private final class RustIndexBuffer { var indices: [UInt32] = []; var received = false }

private final class LayoutMovePlan {
    var insertion: UInt?
    var actions: [UInt] = []
}

private final class LayoutReorderResult {
    var order: [UInt] = []
    var lengths: [UInt] = []
    var page: UInt = 0

    static func receive(_ context: UnsafeMutableRawPointer?, _ order: UnsafePointer<UInt>?, _ count: UInt, _ lengths: UnsafePointer<UInt>?, _ pageCount: UInt, _ page: UInt) {
        guard let context, let order, let lengths, let count = Int(exactly: count), let pageCount = Int(exactly: pageCount) else { return }
        let result = Unmanaged<LayoutReorderResult>.fromOpaque(context).takeUnretainedValue()
        result.order = Array(UnsafeBufferPointer(start: order, count: count))
        result.lengths = Array(UnsafeBufferPointer(start: lengths, count: pageCount))
        result.page = page
    }

    func rebuild(from flat: [LayoutItem], allowsEmpty: Bool) -> [[LayoutItem]]? {
        guard order.count == flat.count, let target = Int(exactly: page), target < lengths.count else { return nil }
        var seen = [UInt8](repeating: 0, count: flat.count)
        for value in order {
            guard value < UInt(flat.count) else { return nil }
            let index = Int(value)
            guard seen[index] == 0 else { return nil }
            seen[index] = 1
        }
        var rebuilt: [[LayoutItem]] = []
        var offset = 0
        for length in lengths {
            guard let length = Int(exactly: length), (allowsEmpty || length > 0), length <= flat.count - offset else { return nil }
            rebuilt.append(order[offset..<(offset + length)].map { flat[Int($0)] })
            offset += length
        }
        return offset == flat.count ? rebuilt : nil
    }
}
public enum LayoutBackupError: Error {
    case invalidFormat
    case changedDuringRestore
    case saveFailed
}

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
    /// Fires when something the search index is built from changes — the
    /// hidden-app set, or an app's alias. Distinct from `onChange`, which the
    /// grid uses to redraw itself and which the launcher's search list does
    /// not observe.
    public var onSearchableRecordsChange: (() -> Void)?

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
        orderDidChange()
    }

    /// The grid redraws on `onChange`, but launcher search lists apps in the grid's
    /// order and listens to something else; without telling it too, results with
    /// equal rank kept the order from before the last move.
    private func orderDidChange() {
        onChange?()
        onSearchableRecordsChange?()
    }

    nonisolated private static func repackWithRust(_ pages: [[LayoutItem]], capacity: Int) -> [[LayoutItem]]? {
        let flat = pages.flatMap { $0 }
        let result = LayoutReorderResult()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt>?, UInt, UnsafePointer<UInt>?, UInt, UInt) -> Void = { LayoutReorderResult.receive($0, $1, $2, $3, $4, $5) }
        let status = launchpad_layout_repack(UInt(flat.count), UInt(max(capacity, 1)), Unmanaged.passUnretained(result).toOpaque(), callback)
        guard status == 1 else { return nil }
        return result.rebuild(from: flat, allowsEmpty: true)
    }

    private func reflowPagesToCurrentCapacity() {
        guard pages.contains(where: { !$0.isEmpty }), let repacked = Self.repackWithRust(pages, capacity: capacityPerPage) else { return }
        pages = repacked
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

    public var wallpaperBlurRadius: Double { document.wallpaperBlurRadius }

    public func setWallpaperBlurRadius(_ value: Double) {
        guard value.isFinite else { return }
        document.wallpaperBlurRadius = min(max(value, 0), 40)
    }

    public var returnToFirstPage: Bool { document.returnToFirstPage }

    public func setReturnToFirstPage(_ value: Bool) {
        document.returnToFirstPage = value
    }

    public var closeOnBackgroundClick: Bool { document.closeOnBackgroundClick }

    public func setCloseOnBackgroundClick(_ value: Bool) {
        document.closeOnBackgroundClick = value
    }

    public var screenTarget: LauncherScreenTarget { document.screenTarget }

    public func setScreenTarget(_ value: LauncherScreenTarget) {
        document.screenTarget = value
    }

    public var menuIconVisibility: MenuIconVisibility {
        document.menuIconVisibility
    }

    /// No `onChange`: every menu takes the setting as it opens — the grid's
    /// are built then, and the folder panel applies it to the menu SwiftUI
    /// hands over (`FolderGridHostingView`) — so nothing needs redrawing.
    public func setMenuIconVisibility(_ value: MenuIconVisibility) {
        document.menuIconVisibility = value
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
        orderDidChange()
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

    /// Last-launch times keyed the way `ApplicationRecord.id` is, for search
    /// ranking. The grid's own order is deliberately left alone — see
    /// `recordLaunch`.
    public var lastLaunchDatesByRecordID: [String: Date] {
        var dates: [String: Date] = [:]
        dates.reserveCapacity(document.lastUsedByID.count)
        for (identifier, date) in document.lastUsedByID {
            dates[identifier.value] = date
        }
        return dates
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
    nonisolated static func rustRecordOrder(recordIDs: [String], placedIDs: [String]) -> [Int]? {
        guard let recordCount = UInt32(exactly: recordIDs.count), let placedCount = UInt32(exactly: placedIDs.count) else { return nil }
        var wire = Data()
        for count in [recordCount, placedCount] {
            var little = count.littleEndian
            withUnsafeBytes(of: &little) { wire.append(contentsOf: $0) }
        }
        for group in [recordIDs, placedIDs] {
            for id in group {
                let normalized = id.utf8.allSatisfy { $0 < 0x80 } ? id : id.precomposedStringWithCanonicalMapping
                let bytes = normalized.utf8
                guard let count = UInt32(exactly: bytes.count), count != UInt32.max else { return nil }
                var little = count.littleEndian
                withUnsafeBytes(of: &little) { wire.append(contentsOf: $0) }
                wire.append(contentsOf: bytes)
            }
        }
        let output = RustIndexBuffer()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt32>?, UInt) -> Void = { context, indices, count in
            guard let context, let indices, let count = Int(exactly: count) else { return }
            Unmanaged<RustIndexBuffer>.fromOpaque(context).takeUnretainedValue().indices = Array(UnsafeBufferPointer(start: indices, count: count))
        }
        let status = wire.withUnsafeBytes { bytes in
            launchpad_order_records(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count), Unmanaged.passUnretained(output).toOpaque(), callback)
        }
        guard status == 1, output.indices.count == recordIDs.count else { return nil }
        // Validate the returned permutation without retaining a second hash table.
        var seen = [UInt8](repeating: 0, count: recordIDs.count)
        var result: [Int] = []
        result.reserveCapacity(recordIDs.count)
        for value in output.indices {
            let index = Int(value)
            guard recordIDs.indices.contains(index), seen[index] == 0 else { return nil }
            seen[index] = 1
            result.append(index)
        }
        return result
    }


    nonisolated private static func appendWireIdentifier(_ id: String, to wire: inout Data) -> Bool {
        var normalized = id.utf8.allSatisfy { $0 < 0x80 } ? id : id.precomposedStringWithCanonicalMapping
        return normalized.withUTF8 { bytes in
            guard let length = UInt32(exactly: bytes.count), length != UInt32.max else { return false }
            var little = length.littleEndian
            withUnsafeBytes(of: &little) { wire.append(contentsOf: $0) }
            wire.append(contentsOf: bytes)
            return true
        }
    }

    nonisolated static func rustUnplacedRecords(
        records: [ApplicationRecord], showMenuBar: Bool, hidden: Set<String>, placed: Set<String>
    ) -> [ApplicationRecord]? {
        guard let recordCount = UInt32(exactly: records.count),
              let hiddenCount = UInt32(exactly: hidden.count),
              let placedCount = UInt32(exactly: placed.count) else { return nil }
        var wire = Data()
        let itemCount = records.count.addingReportingOverflow(hidden.count)
        let totalCount = itemCount.partialValue.addingReportingOverflow(placed.count)
        if !itemCount.overflow, !totalCount.overflow {
            wire.reserveCapacity(12 + min(totalCount.partialValue, 10_000) * 64)
        }
        for count in [recordCount, hiddenCount, placedCount] {
            var little = count.littleEndian
            withUnsafeBytes(of: &little) { wire.append(contentsOf: $0) }
        }
        for id in hidden { guard appendWireIdentifier(id, to: &wire) else { return nil } }
        for id in placed { guard appendWireIdentifier(id, to: &wire) else { return nil } }
        for record in records {
            wire.append(!record.isBackgroundOnly && (showMenuBar || !record.isMenuBarApp) ? 1 : 0)
            guard appendWireIdentifier(record.id.value, to: &wire) else { return nil }
        }
        let output = RustIndexBuffer()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt32>?, UInt) -> Void = { context, indices, count in
            guard let context, let indices, let count = Int(exactly: count) else { return }
            let output = Unmanaged<RustIndexBuffer>.fromOpaque(context).takeUnretainedValue()
            output.indices = Array(UnsafeBufferPointer(start: indices, count: count))
            output.received = true
        }
        let status = wire.withUnsafeBytes { bytes in
            launchpad_unplaced_records(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count), Unmanaged.passUnretained(output).toOpaque(), callback)
        }
        guard status == 1, output.received else { return nil }
        var selected: [ApplicationRecord] = []
        selected.reserveCapacity(output.indices.count)
        var previous = -1
        for raw in output.indices {
            let index = Int(raw)
            guard records.indices.contains(index), index > previous else { return nil }
            let record = records[index]
            guard !record.isBackgroundOnly, showMenuBar || !record.isMenuBarApp,
                  !hidden.contains(record.id.value), !placed.contains(record.id.value) else { return nil }
            selected.append(record)
            previous = index
        }
        return selected
    }

    nonisolated static func rustMissingDateIndices(
        ordered: [StableAppIdentifier], existing: [StableAppIdentifier: Date]
    ) -> [Int]? {
        guard let existingCount = UInt32(exactly: existing.count),
              let candidateCount = UInt32(exactly: ordered.count) else { return nil }
        var wire = Data()
        let total = existing.count.addingReportingOverflow(ordered.count)
        if !total.overflow { wire.reserveCapacity(8 + min(total.partialValue, 10_000) * 64) }
        for count in [existingCount, candidateCount] {
            var little = count.littleEndian
            withUnsafeBytes(of: &little) { wire.append(contentsOf: $0) }
        }
        for id in existing.keys { guard appendWireIdentifier(id.value, to: &wire) else { return nil } }
        for id in ordered { guard appendWireIdentifier(id.value, to: &wire) else { return nil } }
        let output = RustIndexBuffer()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt32>?, UInt) -> Void = { context, indices, count in
            guard let context, let indices, let count = Int(exactly: count) else { return }
            let output = Unmanaged<RustIndexBuffer>.fromOpaque(context).takeUnretainedValue()
            output.indices = Array(UnsafeBufferPointer(start: indices, count: count))
            output.received = true
        }
        let status = wire.withUnsafeBytes { bytes in
            launchpad_missing_dates(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count), Unmanaged.passUnretained(output).toOpaque(), callback)
        }
        guard status == 1, output.received else { return nil }
        var result: [Int] = []
        result.reserveCapacity(output.indices.count)
        var previous = -1
        for raw in output.indices {
            let index = Int(raw)
            guard ordered.indices.contains(index), index > previous, existing[ordered[index]] == nil else { return nil }
            result.append(index)
            previous = index
        }
        return result
    }

    nonisolated static func rustInvalidIdentifiers(valid: Set<String>, candidates: [String]) -> Set<String>? {
        guard let candidateCount = UInt32(exactly: candidates.count),
              let validCount = UInt32(exactly: valid.count) else { return nil }
        var wire = Data()
        let total = valid.count.addingReportingOverflow(candidates.count)
        if !total.overflow { wire.reserveCapacity(12 + min(total.partialValue, 10_000) * 64) }
        for count in [candidateCount, validCount, UInt32(0)] {
            var little = count.littleEndian
            withUnsafeBytes(of: &little) { wire.append(contentsOf: $0) }
        }
        for id in valid { guard appendWireIdentifier(id, to: &wire) else { return nil } }
        for id in candidates {
            wire.append(1)
            guard appendWireIdentifier(id, to: &wire) else { return nil }
        }
        let output = RustIndexBuffer()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt32>?, UInt) -> Void = { context, indices, count in
            guard let context, let indices, let count = Int(exactly: count) else { return }
            let output = Unmanaged<RustIndexBuffer>.fromOpaque(context).takeUnretainedValue()
            output.indices = Array(UnsafeBufferPointer(start: indices, count: count))
            output.received = true
        }
        let status = wire.withUnsafeBytes { bytes in
            launchpad_unplaced_records(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count), Unmanaged.passUnretained(output).toOpaque(), callback)
        }
        guard status == 1, output.received else { return nil }
        var invalid = Set<String>()
        var previous = -1
        for raw in output.indices {
            let index = Int(raw)
            guard candidates.indices.contains(index), index > previous, !valid.contains(candidates[index]) else { return nil }
            invalid.insert(candidates[index])
            previous = index
        }
        return invalid
    }

    public func orderedRecords(from records: [ApplicationRecord]) -> [ApplicationRecord] {
        var placed: [String] = []
        for page in pages {
            for item in page {
                switch item {
                case .app(let id): placed.append(id.value)
                case .folder(let folderID):
                    for folderPage in folders[folderID]?.pages ?? [] {
                        for folderItem in folderPage {
                            if case .app(let id) = folderItem { placed.append(id.value) }
                        }
                    }
                }
            }
        }
        guard let indices = Self.rustRecordOrder(recordIDs: records.map { $0.id.value }, placedIDs: placed) else {
            return orderedRecordsFallback(from: records)
        }
        return indices.map { records[$0] }
    }

    private func orderedRecordsFallback(from records: [ApplicationRecord]) -> [ApplicationRecord] {
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
        let previousKnown = document.knownApplications

        var indexed = Dictionary<String, ApplicationRecord>(minimumCapacity: records.count)
        for record in records {
            let existing = indexed.updateValue(record, forKey: record.id.value)
            precondition(existing == nil, "Duplicate application identifier")
        }
        recordsByIDValue = indexed
        // Before anything is pruned: an app that has moved looks, to the code
        // below, like one that was uninstalled and another that was installed.
        if prunesMissingItems {
            migrateMovedApplications(previousRecords: previousRecords)
        }
        let hiddenIDs = Set(document.hiddenApplicationIDs.map(\.value))
        if prunesMissingItems {
            var validIDs = Set<String>()
            validIDs.reserveCapacity(records.count)
            for record in records where isEligibleForGrid(record) && !hiddenIDs.contains(record.id.value) {
                validIDs.insert(record.id.value)
            }
            pruneMissingItems(validIDs: validIDs)
        }
        backfillMissingDateAdded()

        let placedIDs = allPlacedAppIdentifierValues()
        var newRecords = Self.rustUnplacedRecords(records: records, showMenuBar: showMenuBarApplications, hidden: hiddenIDs, placed: placedIDs)
            ?? records.filter { isEligibleForGrid($0) && !hiddenIDs.contains($0.id.value) && !placedIDs.contains($0.id.value) }
        newRecords.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        for record in newRecords {
            let identifier = record.id.asPersistenceIdentifier
            appendToLastPage(.app(identifier))
            document.dateAddedByID[identifier] = Date()
        }

        rememberKnownApplications()

        let changed = previousRecords != recordsByIDValue
            || previousPages != pages
            || previousFolders != folders
            || previousDateAdded != document.dateAddedByID
            || previousKnown != document.knownApplications
        if changed {
            onChange?()
        }
        return changed
    }

    // MARK: Moved applications

    private func fingerprint(of record: ApplicationRecord) -> KnownApplication {
        KnownApplication(bundleIdentifier: record.bundleIdentifier, teamIdentifier: record.teamIdentifier)
    }

    /// Every identifier the layout refers to anywhere: placed, renamed, hidden,
    /// or carrying a date.
    private func referencedIdentifierValues() -> Set<String> {
        var values = allPlacedAppIdentifierValues()
        values.formUnion(document.aliases.keys.lazy.map(\.value))
        values.formUnion(document.hiddenApplicationIDs.lazy.map(\.value))
        values.formUnion(document.dateAddedByID.keys.lazy.map(\.value))
        values.formUnion(document.lastUsedByID.keys.lazy.map(\.value))
        return values
    }

    /// Records, for every app known now and every app the layout still refers
    /// to, what is needed to recognise it after it moves.
    private func rememberKnownApplications() {
        let referenced = referencedIdentifierValues()
        var known = document.knownApplications.filter {
            referenced.contains($0.key.value) && recordsByIDValue[$0.key.value] == nil
        }
        for record in recordsByIDValue.values {
            known[record.id.asPersistenceIdentifier] = fingerprint(of: record)
        }
        document.knownApplications = known
    }

    /// Carries what the layout holds for an app that has moved over to the app
    /// at its new path.
    ///
    /// An identifier the layout refers to but the catalog no longer has is
    /// matched with a catalog app the layout has never seen, when both are the
    /// same bundle identifier and signing team and there is exactly one of each.
    /// Two of either is ambiguous — which copy went where cannot be told — and is
    /// left alone, as it always was.
    nonisolated static func rustFingerprintMatches(_ old: [KnownApplication], _ new: [KnownApplication]) -> [(Int, Int)]? {
        guard let oldCount = UInt32(exactly: old.count), let newCount = UInt32(exactly: new.count) else { return nil }
        var wire = Data()
        for count in [oldCount, newCount] {
            var little = count.littleEndian
            withUnsafeBytes(of: &little) { wire.append(contentsOf: $0) }
        }
        func append(_ value: String?) -> Bool {
            guard let value else {
                var marker = UInt32.max.littleEndian
                withUnsafeBytes(of: &marker) { wire.append(contentsOf: $0) }
                return true
            }
            let normalized = value.utf8.allSatisfy { $0 < 0x80 } ? value : value.precomposedStringWithCanonicalMapping
            let bytes = normalized.utf8
            guard let count = UInt32(exactly: bytes.count), count != UInt32.max else { return false }
            var little = count.littleEndian
            withUnsafeBytes(of: &little) { wire.append(contentsOf: $0) }
            wire.append(contentsOf: bytes)
            return true
        }
        for group in [old, new] {
            for item in group {
                guard append(item.bundleIdentifier), append(item.teamIdentifier) else { return nil }
            }
        }
        let output = RustIndexBuffer()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt32>?, UInt) -> Void = { context, indices, count in
            guard let context, let indices, let count = Int(exactly: count) else { return }
            Unmanaged<RustIndexBuffer>.fromOpaque(context).takeUnretainedValue().indices = Array(UnsafeBufferPointer(start: indices, count: count))
        }
        let status = wire.withUnsafeBytes { bytes in
            launchpad_match_moved_apps(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count), Unmanaged.passUnretained(output).toOpaque(), callback)
        }
        guard status == 1, output.indices.count.isMultiple(of: 2) else { return nil }
        var result: [(Int, Int)] = []
        var seenOld = [UInt8](repeating: 0, count: old.count)
        var seenNew = [UInt8](repeating: 0, count: new.count)
        for index in stride(from: 0, to: output.indices.count, by: 2) {
            let oldIndex = Int(output.indices[index])
            let newIndex = Int(output.indices[index + 1])
            guard old.indices.contains(oldIndex), new.indices.contains(newIndex), old[oldIndex] == new[newIndex],
                  seenOld[oldIndex] == 0, seenNew[newIndex] == 0 else { return nil }
            seenOld[oldIndex] = 1
            seenNew[newIndex] = 1
            result.append((oldIndex, newIndex))
        }
        return result
    }

    private func migrateMovedApplications(previousRecords: [String: ApplicationRecord]) {
        let referenced = referencedIdentifierValues()
        let orphans = referenced.filter { recordsByIDValue[$0] == nil }.compactMap { id -> (String, KnownApplication)? in
            guard let known = previousRecords[id].map(fingerprint(of:)) ?? document.knownApplications[StableAppIdentifier(value: id)] else { return nil }
            return (id, known)
        }
        guard !orphans.isEmpty else { return }
        let newcomers = recordsByIDValue.values.filter { !referenced.contains($0.id.value) }
        guard !newcomers.isEmpty else { return }
        let oldFingerprints = orphans.map(\.1)
        let newFingerprints = newcomers.map(fingerprint(of:))
        if let pairs = Self.rustFingerprintMatches(oldFingerprints, newFingerprints) {
            for (old, new) in pairs {
                remapIdentifier(from: StableAppIdentifier(value: orphans[old].0), to: newcomers[new].id.asPersistenceIdentifier)
            }
            return
        }
        // Preserve the existing layout if the Rust boundary rejects its input.
        var orphansByApp: [KnownApplication: [String]] = [:]
        for (id, known) in orphans { orphansByApp[known, default: []].append(id) }
        var newcomersByApp: [KnownApplication: [ApplicationRecord]] = [:]
        for record in newcomers { newcomersByApp[fingerprint(of: record), default: []].append(record) }
        for (app, olds) in orphansByApp {
            guard olds.count == 1, let news = newcomersByApp[app], news.count == 1 else { continue }
            remapIdentifier(from: StableAppIdentifier(value: olds[0]), to: news[0].id.asPersistenceIdentifier)
        }
    }

    private func remapIdentifier(from old: StableAppIdentifier, to new: StableAppIdentifier) {
        func swapped(_ item: LayoutItem) -> LayoutItem {
            if case .app(let id) = item, id == old { return .app(new) }
            return item
        }
        pages = pages.map { $0.map(swapped) }
        for (folderID, folder) in folders {
            folders[folderID]?.pages = folder.pages.map { $0.map(swapped) }
        }
        if let alias = document.aliases.removeValue(forKey: old) { document.aliases[new] = alias }
        if document.hiddenApplicationIDs.remove(old) != nil { document.hiddenApplicationIDs.insert(new) }
        if let added = document.dateAddedByID.removeValue(forKey: old) { document.dateAddedByID[new] = added }
        if let used = document.lastUsedByID.removeValue(forKey: old) { document.lastUsedByID[new] = used }
        document.knownApplications.removeValue(forKey: old)
    }

    /// Apps that predate `dateAddedByID` have no timestamp, which would leave
    /// `SortMode.dateAdded` arbitrary across someone's entire existing grid.
    /// Each is backfilled from its current position — apps are appended over
    /// time, so position is the best available proxy. Anchored to the epoch so
    /// backfilled values always sort older than genuinely new ones.
    private func backfillMissingDateAdded() {
        var ordered: [StableAppIdentifier] = []
        for page in pages {
            for case .app(let id) in page { ordered.append(id) }
        }
        for folderID in folders.keys.sorted(by: { $0.value < $1.value }) {
            guard let folder = folders[folderID] else { continue }
            for page in folder.pages {
                for case .app(let id) in page { ordered.append(id) }
            }
        }
        guard ordered.contains(where: { document.dateAddedByID[$0] == nil }) else { return }
        if let indices = Self.rustMissingDateIndices(ordered: ordered, existing: document.dateAddedByID) {
            var position = 0
            for index in indices where document.dateAddedByID[ordered[index]] == nil {
                document.dateAddedByID[ordered[index]] = Date(timeIntervalSince1970: TimeInterval(position))
                position += 1
            }
        } else {
            var position = 0
            for id in ordered where document.dateAddedByID[id] == nil {
                document.dateAddedByID[id] = Date(timeIntervalSince1970: TimeInterval(position))
                position += 1
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
        func missing(_ item: LayoutItem) -> Bool {
            guard case .app(let id) = item else { return false }
            return !validIDs.contains(id.value)
        }
        let needsPruning = pages.contains { $0.contains(where: missing) }
            || folders.values.contains { folder in folder.pages.contains { $0.contains(where: missing) } }
        let emptyPage = pages.isEmpty || pages.contains(where: \.isEmpty)
        let emptyFolder = folders.values.contains { $0.pages.allSatisfy(\.isEmpty) }
        guard needsPruning || emptyPage || emptyFolder else { return }
        var invalid: Set<String>?
        if needsPruning {
            var candidates: [String] = []
            for page in pages {
                for case .app(let id) in page { candidates.append(id.value) }
            }
            for folder in folders.values {
                for page in folder.pages {
                    for case .app(let id) in page { candidates.append(id.value) }
                }
            }
            invalid = Self.rustInvalidIdentifiers(valid: validIDs, candidates: candidates)
            if invalid?.isEmpty == true { invalid = nil }
        } else {
            invalid = []
        }
        func isValid(_ id: String) -> Bool {
            if let invalid { return !invalid.contains(id) }
            return validIDs.contains(id)
        }
        for pageIndex in pages.indices {
            let before = pages[pageIndex]
            pages[pageIndex] = before.filter { item in
                guard case .app(let id) = item else { return true }
                return isValid(id.value)
            }
            let removed = before.count - pages[pageIndex].count
            if removed > 0 {
                let removedIDs = before.compactMap { item -> String? in
                    guard case .app(let id) = item, !isValid(id.value) else { return nil }
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
                    let keep = isValid(id.value)
                    if !keep {
                        prunedFromFolder += 1
                        removedFromFolder.append(id.value)
                    }
                    return keep
                }
            }
            if prunedFromFolder > 0 {
                // Same reason `removeFromFolder` compacts: filtering in place
                // leaves a hole in whichever page lost items, and the folder
                // is paged, so the user swipes to a half-empty page — or past
                // an entirely empty one — until the next launch repacks it.
                folder.pages = Self.folderPagesRepacked(folder.pages, capacity: gridSettings.folderGridSize)
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
        pages.removeAll(where: \.isEmpty)
        if pages.isEmpty { pages = [[]] }
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


    nonisolated private static func validatedOverflowActions(
        _ raw: [UInt], sizes initial: [Int], start: Int, capacity: Int
    ) -> [(Int, Int)]? {
        guard start >= 0, capacity > 0, raw.count.isMultiple(of: 2) else { return nil }
        var sizes = initial
        var expectedPage = start
        var result: [(Int, Int)] = []
        for index in stride(from: 0, to: raw.count, by: 2) {
            guard let page = Int(exactly: raw[index]), let overflow = Int(exactly: raw[index + 1]),
                  page == expectedPage, sizes.indices.contains(page), sizes[page] > capacity,
                  overflow == sizes[page] - capacity else { return nil }
            sizes[page] -= overflow
            if page + 1 == sizes.count { sizes.append(0) }
            let next = sizes[page + 1].addingReportingOverflow(overflow)
            guard !next.overflow else { return nil }
            sizes[page + 1] = next.partialValue
            result.append((page, overflow))
            expectedPage += 1
        }
        guard !sizes.indices.contains(expectedPage) || sizes[expectedPage] <= capacity else { return nil }
        return result
    }

    nonisolated private static func applyOverflowActions(_ actions: [(Int, Int)], to pages: inout [[LayoutItem]]) {
        for (page, overflow) in actions {
            let moved = Array(pages[page].suffix(overflow))
            pages[page].removeLast(overflow)
            if page + 1 == pages.count { pages.append(moved) }
            else { pages[page + 1].insert(contentsOf: moved, at: 0) }
        }
    }

    nonisolated private static func moveWithRust(_ pages: inout [[LayoutItem]], fromPage: Int, fromIndex: Int, toPage: Int, toIndex: Int, capacity: Int) -> Bool {
        guard pages.indices.contains(fromPage), pages[fromPage].indices.contains(fromIndex), toPage >= 0 else { return false }
        let counts = pages.map { UInt($0.count) }
        let plan = LayoutMovePlan()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UInt, UnsafePointer<UInt>?, UInt) -> Void = { context, insertion, actions, count in
            guard let context, let actions, let count = Int(exactly: count) else { return }
            let plan = Unmanaged<LayoutMovePlan>.fromOpaque(context).takeUnretainedValue()
            plan.insertion = insertion
            plan.actions = Array(UnsafeBufferPointer(start: actions, count: count))
        }
        let status = counts.withUnsafeBufferPointer { buffer in
            launchpad_layout_move_one(buffer.baseAddress, UInt(buffer.count), UInt(fromPage), UInt(fromIndex), UInt(toPage), UInt(max(toIndex, 0)), UInt(capacity), Unmanaged.passUnretained(plan).toOpaque(), callback)
        }
        guard status == 1, let rawInsertion = plan.insertion, let insertion = Int(exactly: rawInsertion), plan.actions.count.isMultiple(of: 2) else { return false }
        var sizes = pages.map(\.count)
        sizes[fromPage] -= 1
        while sizes.count <= toPage { sizes.append(0) }
        guard insertion <= sizes[toPage] else { return false }
        sizes[toPage] += 1
        guard let actions = validatedOverflowActions(plan.actions, sizes: sizes, start: toPage, capacity: capacity) else { return false }
        let item = pages[fromPage].remove(at: fromIndex)
        while pages.count <= toPage { pages.append([]) }
        pages[toPage].insert(item, at: insertion)
        applyOverflowActions(actions, to: &pages)
        return true
    }

    public func moveItem(fromPage: Int, fromIndex: Int, toPage: Int, toIndex: Int) {
        let capacity = capacityPerPage
        guard Self.moveWithRust(&pages, fromPage: fromPage, fromIndex: fromIndex, toPage: toPage, toIndex: toIndex, capacity: capacity) else { return }
        orderDidChange()
    }

    private func reorderWithRust(_ items: Set<LayoutItem>, leader: LayoutItem, toPage: Int, toIndex: Int) -> Int? {
        let flat = pages.flatMap { $0 }
        guard let leaderIndex = flat.firstIndex(of: leader), flat.filter({ items.contains($0) }).count == items.count else { return nil }
        let counts = pages.map { UInt($0.count) }
        let selected = flat.map { UInt8(items.contains($0) ? 1 : 0) }
        let result = LayoutReorderResult()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt>?, UInt, UnsafePointer<UInt>?, UInt, UInt) -> Void = { LayoutReorderResult.receive($0, $1, $2, $3, $4, $5) }
        let status = counts.withUnsafeBufferPointer { countBuffer in
            selected.withUnsafeBufferPointer { selectionBuffer in
                launchpad_layout_reorder(countBuffer.baseAddress, UInt(countBuffer.count), selectionBuffer.baseAddress, UInt(selectionBuffer.count), UInt(leaderIndex), UInt(toPage), UInt(max(toIndex, 0)), UInt(capacityPerPage), Unmanaged.passUnretained(result).toOpaque(), callback)
            }
        }
        guard status == 1, let rebuilt = result.rebuild(from: flat, allowsEmpty: false), let target = Int(exactly: result.page) else { return nil }
        pages = rebuilt
        return target
    }

    @discardableResult
    public func moveItems(_ items: Set<LayoutItem>, leader: LayoutItem, toPage: Int, toIndex: Int, folderTarget: LayoutItem? = nil) -> Int? {
        guard !items.isEmpty, items.contains(leader), pages.indices.contains(toPage) else { return nil }
        if folderTarget == nil {
            guard let page = reorderWithRust(items, leader: leader, toPage: toPage, toIndex: toIndex) else { return nil }
            orderDidChange()
            return page
        }
        let ordered = pages.flatMap { $0 }.filter { items.contains($0) }
        guard ordered.count == items.count else { return nil }
        let destination = pages[toPage]
        if let target = folderTarget {
            guard !items.contains(target), destination.contains(target),
                  ordered.allSatisfy({ if case .app = $0 { return true }; return false }) else { return nil }
            var folder: Folder
            switch target {
            case .app:
                folder = Folder(name: L10n.defaultFolderName, pages: [[]])
                appendToFolder(&folder, item: target)
            case .folder(let id):
                guard let existing = folders[id] else { return nil }
                folder = existing
            }
            for item in ordered { appendToFolder(&folder, item: item) }
            folders[folder.id] = folder
            for page in pages.indices { pages[page].removeAll { items.contains($0) } }
            guard let targetIndex = pages[toPage].firstIndex(of: target) else { return nil }
            pages[toPage][targetIndex] = .folder(folder.id)
        }
        let resultPage = toPage - pages[..<toPage].filter(\.isEmpty).count
        pages.removeAll(where: \.isEmpty)
        if pages.isEmpty { pages = [[]] }
        orderDidChange()
        return min(resultPage, pages.count - 1)
    }



    /// Pushes whatever no longer fits off the end of a page onto the next one,
    /// carrying on for as long as pages overflow and adding a page at the end
    /// if it runs out — the way the real Launchpad absorbs a drop onto a full
    /// page.
    ///
    /// Without this, dropping onto a full page simply made it one item longer.
    /// The layout places item *n* at row `n / columns` and the viewport shows
    /// exactly `rows` rows with no scrolling, so the item pushed past the last
    /// slot was laid out below the visible area and vanished — an app the user
    /// could no longer see or launch. It came back only on the next launch,
    /// where `loadDocument` repacks every page, which is itself the disruptive
    /// operation `updateGridSettings` deliberately avoids running on its own.
    private func cascadeOverflow(from page: Int) {
        guard pages.indices.contains(page), pages[page].count > capacityPerPage else { return }
        if page >= 0, capacityPerPage > 0 {
            let counts = pages.map { UInt($0.count) }
            let plan = LayoutMovePlan()
            let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt>?, UInt) -> Void = { context, actions, count in
                guard let context, let actions, let count = Int(exactly: count) else { return }
                let plan = Unmanaged<LayoutMovePlan>.fromOpaque(context).takeUnretainedValue()
                plan.insertion = 0
                plan.actions = Array(UnsafeBufferPointer(start: actions, count: count))
            }
            let status = counts.withUnsafeBufferPointer { buffer in
                launchpad_layout_overflow(buffer.baseAddress, UInt(buffer.count), UInt(page), UInt(capacityPerPage), Unmanaged.passUnretained(plan).toOpaque(), callback)
            }
            if status == 1, plan.insertion != nil,
               let actions = Self.validatedOverflowActions(plan.actions, sizes: pages.map(\.count), start: page, capacity: capacityPerPage) {
                Self.applyOverflowActions(actions, to: &pages)
                return
            }
        }
        var index = page
        while pages.indices.contains(index), pages[index].count > capacityPerPage {
            let overflow = pages[index].removeLast()
            if index + 1 == pages.count {
                pages.append([overflow])
            } else {
                pages[index + 1].insert(overflow, at: 0)
            }
            // Only move on once this page fits: it can be over by more than
            // one if the capacity shrank while items were already placed.
            if pages[index].count <= capacityPerPage {
                index += 1
            }
        }
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
        let capacity = max(folder.pages[page].count, 1)
        guard Self.moveWithRust(&folder.pages, fromPage: page, fromIndex: fromIndex, toPage: page, toIndex: toIndex, capacity: capacity) else { return }
        folders[folderID] = folder
        orderDidChange()
    }

    /// Dragging one item onto another: onto a bare app, both merge into a new
    /// folder; onto an existing folder, the dragged item joins it.
    public func createOrJoinFolder(sourcePage: Int, sourceIndex: Int, destinationPage: Int, destinationIndex: Int, defaultFolderName: String = L10n.defaultFolderName) {
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
        orderDidChange()
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
        repackWithRust(pages, capacity: capacity) ?? pages
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
        // Dragging out of a folder is the other way an item reaches a page,
        // and the page it lands on can already be full — same disappearing
        // act as a drop, so it needs the same cascade.
        cascadeOverflow(from: toPage)

        if isFolderEmpty(folderID) {
            dissolveFolder(folderID)
        }
        orderDidChange()
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
        orderDidChange()
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
        onSearchableRecordsChange?()
    }

    public func unhideApplication(_ identifier: StableAppIdentifier) {
        document.hiddenApplicationIDs.remove(identifier)
        if recordsByIDValue[identifier.value] != nil, !allPlacedAppIdentifierValues().contains(identifier.value) {
            appendToLastPage(.app(identifier))
        }
        onChange?()
        onSearchableRecordsChange?()
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
        onSearchableRecordsChange?()
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

    /// Whether nothing has been arranged yet — the state a legacy import may fill.
    public var hasNoArrangement: Bool {
        folders.isEmpty && pages.allSatisfy(\.isEmpty)
    }

    /// Applies a one-time Classic Launchpad import, but only when this
    /// app's own layout is still completely empty (no pages, no folders) —
    /// i.e. first run, before the user has arranged anything here. Safe to
    /// call on every launch; it's a no-op once real state exists.
    @discardableResult
    public func applyLegacyImportIfFirstRun(_ result: LegacyImportResult) -> Bool {
        let hasExistingArrangement = folders.isEmpty == false || pages.contains { !$0.isEmpty }
        guard result.succeeded, !hasExistingArrangement else { return false }

        for folder in result.folders {
            folders[folder.id] = folder
        }
        // The importer puts a whole folder on one page. A saved layout is split
        // to the folder page size when it loads; an import is applied after
        // that, so without this a large folder stayed on one page — more icons
        // than the panel can show — until the next launch repaired it.
        normalizeFolderPages()
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

    /// True from a save that failed until the next one that works. Most callers
    /// start a save and drop its result, so without this a full disk or an
    /// unwritable folder looked like success until a restart brought back the old
    /// layout.
    public private(set) var saveFailed = false

    /// Called when `saveFailed` changes: once when saving starts failing, once when
    /// it recovers — not on every failed attempt.
    public var onSaveFailureChange: ((Bool) -> Void)?

    private func recordSave(succeeded: Bool) {
        guard saveFailed == succeeded else { return }
        saveFailed = !succeeded
        onSaveFailureChange?(saveFailed)
    }



    private func currentDocument() -> LayoutDocument {
        var current = document
        current.gridSettings = gridSettings
        current.pages = pages
        current.folders = folders
        return current
    }

    private func backupDocument() -> LayoutDocument {
        var backup = LayoutDocument.empty
        backup.gridSettings = gridSettings
        backup.pages = pages
        backup.folders = folders
        backup.aliases = document.aliases
        backup.hiddenApplicationIDs = document.hiddenApplicationIDs
        backup.dateAddedByID = document.dateAddedByID
        backup.lastUsedByID = document.lastUsedByID
        backup.knownApplications = document.knownApplications
        return backup
    }

    public func exportLayoutBackup(to url: URL) async throws {
        let data = try LayoutJSON.encode(backupDocument())
        try await layoutStore.writeBackup(data, to: url)
    }

    public func restoreLayoutBackup(from url: URL) async throws {
        let data = try await layoutStore.readBackup(at: url)
        let backup = try LayoutJSON.decode(data)
        guard backup.schemaVersion == LayoutDocument.currentSchemaVersion,
              backup.pages.count <= 1_000, backup.folders.count <= 1_000 else {
            throw LayoutBackupError.invalidFormat
        }

        var appIDs = Set<StableAppIdentifier>()
        var folderIDs = Set<FolderID>()
        func addApp(_ id: StableAppIdentifier) throws {
            guard !id.value.isEmpty, id.value.utf8.count <= 1_024,
                  appIDs.insert(id).inserted, appIDs.count <= 50_000 else {
                throw LayoutBackupError.invalidFormat
            }
        }
        for page in backup.pages {
            for item in page {
                switch item {
                case .app(let id): try addApp(id)
                case .folder(let id):
                    guard backup.folders[id] != nil, folderIDs.insert(id).inserted else {
                        throw LayoutBackupError.invalidFormat
                    }
                }
            }
        }
        guard folderIDs.count == backup.folders.count else { throw LayoutBackupError.invalidFormat }
        for (id, folder) in backup.folders {
            guard folder.id == id, folder.pages.count <= 1_000 else { throw LayoutBackupError.invalidFormat }
            for page in folder.pages {
                for item in page {
                    guard case .app(let appID) = item else { throw LayoutBackupError.invalidFormat }
                    try addApp(appID)
                }
            }
        }
        guard appIDs.isDisjoint(with: backup.hiddenApplicationIDs) else { throw LayoutBackupError.invalidFormat }

        let before = try LayoutJSON.encode(currentDocument())
        var candidate = currentDocument()
        candidate.gridSettings = backup.gridSettings
        candidate.pages = backup.pages.filter { !$0.isEmpty }
        if candidate.pages.isEmpty { candidate.pages = [[]] }
        candidate.folders = backup.folders
        candidate.aliases = backup.aliases
        candidate.hiddenApplicationIDs = backup.hiddenApplicationIDs
        candidate.dateAddedByID = backup.dateAddedByID
        candidate.lastUsedByID = backup.lastUsedByID
        candidate.knownApplications = backup.knownApplications
        try await layoutStore.save(currentDocument())
        guard try LayoutJSON.encode(currentDocument()) == before else {
            try await layoutStore.save(currentDocument())
            throw LayoutBackupError.changedDuringRestore
        }
        try await layoutStore.save(candidate)

        if try LayoutJSON.encode(currentDocument()) != before {
            try await layoutStore.save(currentDocument())
            throw LayoutBackupError.changedDuringRestore
        }

        document = candidate
        pages = candidate.pages
        folders = candidate.folders
        gridSettings = candidate.gridSettings
        if pages.contains(where: { $0.count > capacityPerPage }) { reflowPagesToCurrentCapacity() }
        _ = normalizeFolderPages()
        _ = reconcile(with: Array(recordsByIDValue.values), prunesMissingItems: false)
        onChange?()
        onSearchableRecordsChange?()
        do {
            try await layoutStore.save(currentDocument(), updateBackup: false)
            recordSave(succeeded: true)
        } catch {
            recordSave(succeeded: false)
            throw LayoutBackupError.saveFailed
        }
    }

    @discardableResult
    public func save() async -> Bool {
        document.pages = pages
        document.folders = folders
        do {
            try await layoutStore.save(document)
            recordSave(succeeded: true)
            return true
        } catch {
            DiagnosticsLog.persistence.error("Failed to save layout: \(String(describing: error), privacy: .public)")
            recordSave(succeeded: false)
            return false
        }
    }

    /// Saves through the same actor-backed store but returns the outcome to a
    /// caller that is coordinating an external transaction.
    @discardableResult
    public func saveResult() async -> Bool {
        document.pages = pages
        document.folders = folders
        let saved = await layoutStore.saveResult(document)
        recordSave(succeeded: saved)
        return saved
    }
}
