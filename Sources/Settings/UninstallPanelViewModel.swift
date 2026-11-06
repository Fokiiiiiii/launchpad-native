import AppKit
import Catalog
import Diagnostics
import Foundation
import Uninstall

@MainActor
public final class UninstallPanelViewModel: ObservableObject {
    public enum SectionKind: CaseIterable {
        case applicationFile, cache, preferences
    }

    public struct Row: Identifiable {
        public let id = UUID()
        public let removalItem: RemovalItem
        public var sizeInBytes: Int64?
        public var icon: NSImage?
        public var isChecked: Bool
        /// sharedRisk/unknown/requiresPrivilegedHelper items are always
        /// shown (never silently hidden) but can never be checked — matches
        /// `RemovalExecutor`'s own permanent refusal to act on them.
        public let isDisabled: Bool
    }

    public let record: ApplicationRecord
    @Published public private(set) var rowsBySection: [SectionKind: [Row]] = [:]
    /// True until the removal plan has been built. It is built off the main
    /// actor — gathering the evidence lists folders and runs `pkgutil` — so the
    /// panel opens at once and fills in.
    @Published public private(set) var isLoadingPlan = true
    @Published public private(set) var isComputingSizes = true
    @Published public private(set) var totalSizeText = "—"
    /// Set only when the removal itself has already completed but its
    /// operation-history report could not be persisted. This is deliberately
    /// separate from `RemovalOutcome`: a report-write failure must never make
    /// an item that was moved to Trash look like a failed removal.
    @Published public private(set) var operationReportError: String?
    /// The app had not quit when it was asked to, so nothing was moved. The
    /// user can quit it (an unsaved document may be holding it open) and
    /// confirm again.
    @Published public private(set) var isBlockedByRunningApp = false
    /// How many of the selected items could not be moved to Trash. The rest
    /// were moved; the list says which.
    @Published public private(set) var failedRemovalCount = 0
    /// What the last confirmed removal did, item by item.
    @Published public private(set) var lastOutcomes: [RemovalOutcome] = []
    /// Prevents a second destructive execution while the first report is
    /// still being persisted (or after a persistence failure leaves this
    /// panel open so the warning can be read).
    @Published public private(set) var hasConfirmedRemoval = false
    @Published public private(set) var isRecordingOperationReport = false

    private let operationReportStore: OperationReportStore
    private let measureSize: @Sendable (URL) async -> Int64?
    private var loadTask: Task<Void, Never>?

    public init(
        record: ApplicationRecord,
        allRecords: [ApplicationRecord],
        operationReportStore: OperationReportStore = OperationReportStore(),
        measureSize: @escaping @Sendable (URL) async -> Int64? = { path in
            await Task.detached { DiskSizeEstimator.estimatedSize(at: path) }.value
        }
    ) {
        self.record = record
        self.operationReportStore = operationReportStore
        self.measureSize = measureSize
        loadTask = Task { await self.load(allRecords: allRecords) }
    }

    /// Resolves once the plan is built and every size has been measured.
    public func waitUntilLoaded() async {
        await loadTask?.value
    }

    private func load(allRecords: [ApplicationRecord]) async {
        let record = self.record
        let plan = await Task.detached(priority: .userInitiated) {
            Self.buildPlan(for: record, allRecords: allRecords)
        }.value

        var grouped: [SectionKind: [Row]] = [:]
        for item in plan {
            let kind = Self.sectionKind(for: item, bundleURL: record.bundleURL)
            let row = Row(
                removalItem: item,
                sizeInBytes: nil,
                icon: nil,
                isChecked: item.classification == .owned && !item.requiresPrivilegedHelper,
                isDisabled: item.classification != .owned || item.requiresPrivilegedHelper
            )
            grouped[kind, default: []].append(row)
        }
        rowsBySection = grouped
        isLoadingPlan = false
        refreshTotal()
        await computeSizes()
    }

    nonisolated private static func buildPlan(for record: ApplicationRecord, allRecords: [ApplicationRecord]) -> [RemovalItem] {
        let evidence = OwnershipEvidenceCollector.collect(for: record)
        var plan = RemovalPlanner.plan(for: record, evidence: evidence, siblingRecords: allRecords)

        // RemovalPlanner never includes the app's own bundle for a normal
        // (non-system-protected) app — synthesize it here so "Move to
        // Trash" can actually remove the app, not just its leftovers.
        // System-protected apps already get a single `.unknown` bundle
        // entry from RemovalPlanner itself; don't add a second one.
        if !record.isSystemProtected {
            plan.insert(RemovalItem(path: record.bundleURL, classification: .owned, requiresPrivilegedHelper: false), at: 0)
        }
        return plan
    }

    private static func sectionKind(for item: RemovalItem, bundleURL: URL) -> SectionKind {
        if item.path == bundleURL { return .applicationFile }
        let path = item.path.path
        if path.contains("/Caches/") || path.contains("/WebKit/") || path.contains("/HTTPStorages/") || path.contains("/Cookies/") || path.contains("/Logs/") {
            return .cache
        }
        if path.contains("/Preferences/") { return .preferences }
        // Application Support/Containers/Saved State/Scripts/LaunchAgents/
        // receipts — grouped with the app's own operational data.
        return .applicationFile
    }

    private func computeSizes() async {
        let targets = rowsBySection.values.flatMap { $0 }.map { ($0.id, $0.removalItem.path) }
        for (id, path) in targets {
            let size = await measureSize(path)
            // NSWorkspace's own icon lookup — same API Finder itself
            // uses, so a folder gets the real folder icon, a plist gets
            // the real plist icon, etc. Works even for paths that don't
            // exist (falls back to a generic icon for the extension),
            // so a missing/already-cleaned-up file never crashes this.
            let icon = NSWorkspace.shared.icon(forFile: path.path)
            applyMeasurement(rowID: id, size: size, icon: icon)
        }
        isComputingSizes = false
        refreshTotal()
    }

    /// Writes only what was measured, into the row as it is *now*. Measuring a
    /// large folder takes long enough for the user to uncheck something in the
    /// meantime, and putting back a copy of the row taken before the wait would
    /// quietly re-select what they had just left out.
    private func applyMeasurement(rowID: UUID, size: Int64?, icon: NSImage) {
        for kind in SectionKind.allCases {
            guard var rows = rowsBySection[kind], let index = rows.firstIndex(where: { $0.id == rowID }) else { continue }
            rows[index].sizeInBytes = size
            rows[index].icon = icon
            rowsBySection[kind] = rows
            return
        }
    }

    private func refreshTotal() {
        let total = rowsBySection.values.flatMap { $0 }.filter(\.isChecked).reduce(Int64(0)) { $0 + ($1.sizeInBytes ?? 0) }
        totalSizeText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    public func setChecked(_ checked: Bool, rowID: UUID) {
        // The selection is fixed once the removal has been confirmed.
        guard !hasConfirmedRemoval else { return }
        for kind in SectionKind.allCases {
            guard var rows = rowsBySection[kind] else { continue }
            guard let index = rows.firstIndex(where: { $0.id == rowID }) else { continue }
            guard !rows[index].isDisabled else { return }
            rows[index].isChecked = checked
            rowsBySection[kind] = rows
            break
        }
        refreshTotal()
    }

    /// Confirms the selected removals. The selection is taken once, here; the
    /// app is asked to quit and given time to; only then are files moved, off
    /// the main actor. `onFinished` is called on the main actor with `true`
    /// only when every selected item was moved *and* the operation-history
    /// report was saved, so the owning window closes only on a clean result.
    public func confirmMoveToTrash(onFinished: ((Bool) -> Void)? = nil) {
        // Every path reports back, so the window never waits on a callback
        // that is not coming.
        guard !hasConfirmedRemoval, !isLoadingPlan else {
            onFinished?(false)
            return
        }
        let checked = rowsBySection.values.flatMap { $0 }.filter(\.isChecked).map(\.removalItem)
        // Nothing selected: ask nothing of the app, move nothing.
        guard !checked.isEmpty else {
            onFinished?(false)
            return
        }

        hasConfirmedRemoval = true
        operationReportError = nil
        isBlockedByRunningApp = false
        failedRemovalCount = 0
        isRecordingOperationReport = true

        let bundleURL = record.bundleURL
        let bundleIdentifier = record.bundleIdentifier
        let operationReportStore = self.operationReportStore
        Task { @MainActor in
            let run = await RemovalCoordinator.run(
                items: checked,
                bundleURL: bundleURL,
                bundleIdentifier: bundleIdentifier
            )
            guard run.status == .completed else {
                // Nothing was moved, so the panel can be confirmed again.
                self.isBlockedByRunningApp = run.status == .blockedByRunningApp
                self.hasConfirmedRemoval = false
                self.isRecordingOperationReport = false
                onFinished?(false)
                return
            }

            self.lastOutcomes = run.outcomes
            self.failedRemovalCount = run.outcomes.filter { !$0.succeeded }.count
            do {
                _ = try await operationReportStore.recordExecution(bundleIdentifier: bundleIdentifier, outcomes: run.outcomes)
                self.isRecordingOperationReport = false
                onFinished?(self.failedRemovalCount == 0)
            } catch {
                let detail = error.localizedDescription
                DiagnosticsLog.uninstall.error(
                    "Failed to record operation report for \(bundleIdentifier, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                self.operationReportError = detail
                self.isRecordingOperationReport = false
                onFinished?(false)
            }
        }
    }
}
