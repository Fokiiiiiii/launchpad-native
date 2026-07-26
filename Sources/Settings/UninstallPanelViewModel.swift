import Catalog
import Foundation
import Uninstall

/// Front-end-only categorization + bundle-row synthesis for the new
/// floating Uninstall panel (Round 12 §6). The restored `Sources/Uninstall/*`
/// files stay byte-for-byte unchanged from before Round 11's removal —
/// `RemovalItem` carries no category and no size, and `RemovalPlanner` never
/// emits an item for the app's own `.app` bundle (only for its related
/// files/launch agents/receipts). Both gaps are filled here, in the view
/// model, rather than by touching the restored backend.
@MainActor
public final class UninstallPanelViewModel: ObservableObject {
    public enum SectionKind: CaseIterable {
        case applicationFile, cache, preferences
    }

    public struct Row: Identifiable {
        public let id = UUID()
        public let removalItem: RemovalItem
        public var sizeInBytes: Int64?
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

    public init(record: ApplicationRecord, allRecords: [ApplicationRecord]) {
        self.record = record
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

    @discardableResult
    public func confirmMoveToTrash() -> [RemovalOutcome] {
        RemovalExecutor.terminateIfRunning(bundleIdentifier: record.bundleIdentifier)
        let checked = rowsBySection.values.flatMap { $0 }.filter(\.isChecked).map(\.removalItem)
        let outcomes = RemovalExecutor.execute(checked)
        let bundleIdentifier = record.bundleIdentifier
        Task { try? await OperationReportStore().recordExecution(bundleIdentifier: bundleIdentifier, outcomes: outcomes) }
        return outcomes
    }
}
