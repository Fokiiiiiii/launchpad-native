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
    @Published public private(set) var isComputingSizes = true
    @Published public private(set) var totalSizeText = "—"
    /// Set only when the removal itself has already completed but its
    /// operation-history report could not be persisted. This is deliberately
    /// separate from `RemovalOutcome`: a report-write failure must never make
    /// an item that was moved to Trash look like a failed removal.
    @Published public private(set) var operationReportError: String?
    /// Prevents a second destructive execution while the first report is
    /// still being persisted (or after a persistence failure leaves this
    /// panel open so the warning can be read).
    @Published public private(set) var hasConfirmedRemoval = false
    @Published public private(set) var isRecordingOperationReport = false

    private let operationReportStore: OperationReportStore

    public init(
        record: ApplicationRecord,
        allRecords: [ApplicationRecord],
        operationReportStore: OperationReportStore = OperationReportStore()
    ) {
        self.record = record
        self.operationReportStore = operationReportStore
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
        Task { await computeSizes() }
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
        for kind in SectionKind.allCases {
            guard var rows = rowsBySection[kind] else { continue }
            for index in rows.indices {
                let path = rows[index].removalItem.path
                rows[index].sizeInBytes = await Task.detached { DiskSizeEstimator.estimatedSize(at: path) }.value
                // NSWorkspace's own icon lookup — same API Finder itself
                // uses, so a folder gets the real folder icon, a plist gets
                // the real plist icon, etc. Works even for paths that don't
                // exist (falls back to a generic icon for the extension),
                // so a missing/already-cleaned-up file never crashes this.
                rows[index].icon = NSWorkspace.shared.icon(forFile: path.path)
            }
            rowsBySection[kind] = rows
        }
        isComputingSizes = false
        let total = rowsBySection.values.flatMap { $0 }.filter(\.isChecked).reduce(Int64(0)) { $0 + ($1.sizeInBytes ?? 0) }
        totalSizeText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    public func setChecked(_ checked: Bool, rowID: UUID) {
        for kind in SectionKind.allCases {
            guard var rows = rowsBySection[kind] else { continue }
            guard let index = rows.firstIndex(where: { $0.id == rowID }) else { continue }
            rows[index].isChecked = checked
            rowsBySection[kind] = rows
            break
        }
        let total = rowsBySection.values.flatMap { $0 }.filter(\.isChecked).reduce(Int64(0)) { $0 + ($1.sizeInBytes ?? 0) }
        totalSizeText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// Executes the selected removals immediately and records the resulting
    /// outcomes asynchronously. `onReportRecorded` is called on the main
    /// actor once the report has either been saved (`true`) or failed (`false`)
    /// so the owning window can close only after a successful history write.
    @discardableResult
    public func confirmMoveToTrash(onReportRecorded: ((Bool) -> Void)? = nil) -> [RemovalOutcome] {
        guard !hasConfirmedRemoval else { return [] }
        hasConfirmedRemoval = true
        operationReportError = nil
        isRecordingOperationReport = true

        RemovalExecutor.terminateIfRunning(bundleIdentifier: record.bundleIdentifier)
        let checked = rowsBySection.values.flatMap { $0 }.filter(\.isChecked).map(\.removalItem)
        let outcomes = RemovalExecutor.execute(checked)
        let bundleIdentifier = record.bundleIdentifier
        let operationReportStore = self.operationReportStore
        Task { @MainActor [weak self] in
            do {
                _ = try await operationReportStore.recordExecution(bundleIdentifier: bundleIdentifier, outcomes: outcomes)
                self?.isRecordingOperationReport = false
                onReportRecorded?(true)
            } catch {
                let detail = error.localizedDescription
                DiagnosticsLog.uninstall.error(
                    "Failed to record operation report for \(bundleIdentifier, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                self?.operationReportError = detail
                self?.isRecordingOperationReport = false
                onReportRecorded?(false)
            }
        }
        return outcomes
    }
}
