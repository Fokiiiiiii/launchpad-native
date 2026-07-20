import Catalog
import Foundation
import Grid
import Persistence
import Uninstall

public enum SettingsTab: Hashable, Sendable {
    case grid, triggers, sources, hidden, uninstall
}

/// Bridges `GridModel` (a plain `@MainActor` class, not `ObservableObject`)
/// into SwiftUI's `@Published` world. Mutations write straight through to
/// `GridModel` and persist immediately — there's no separate "unsaved
/// changes" state to reason about.
@MainActor
public final class SettingsViewModel: ObservableObject {
    private let model: GridModel
    private let onTriggerSettingsChanged: () -> Void

    @Published public var selectedTab: SettingsTab = .grid
    @Published public var columns: Int
    @Published public var rows: Int
    @Published public var iconSize: Double
    @Published public var layoutMode: LayoutMode

    @Published public var f4Enabled: Bool
    @Published public var hotkeyEnabled: Bool
    @Published public var hotCornerTopLeft: Bool
    @Published public var hotCornerTopRight: Bool
    @Published public var hotCornerBottomLeft: Bool
    @Published public var hotCornerBottomRight: Bool
    @Published public var multitouchEnabled: Bool
    @Published public var multitouchSensitivity: Double

    @Published public var customSources: [CustomSourceConfig]
    @Published public var hiddenApps: [(identifier: StableAppIdentifier, name: String)]

    /// Every non-system-protected app, offered as an Uninstall candidate.
    /// System-protected apps are excluded from the picker entirely rather
    /// than shown disabled — `RemovalPlanner` would reject them anyway, and
    /// there is nothing useful for the user to see about them here.
    @Published public var uninstallCandidates: [ApplicationRecord] = []
    @Published public var selectedUninstallRecordID: StableAppID?
    /// The dry-run plan for the selected candidate. This phase never
    /// executes it — computing it is read-only (evidence collection +
    /// pure classification), so it's safe to recompute on every selection.
    @Published public var uninstallPlan: [RemovalItem] = []

    private let reportStore = OperationReportStore()

    public init(model: GridModel, onTriggerSettingsChanged: @escaping () -> Void) {
        self.model = model
        self.onTriggerSettingsChanged = onTriggerSettingsChanged

        let grid = model.gridSettings
        columns = grid.columns
        rows = grid.rows
        iconSize = grid.iconSize
        layoutMode = model.layoutMode

        let triggers = model.triggerSettings
        f4Enabled = triggers.f4Enabled
        hotkeyEnabled = triggers.hotkeyEnabled
        hotCornerTopLeft = triggers.hotCornersEnabled["topLeft"] ?? false
        hotCornerTopRight = triggers.hotCornersEnabled["topRight"] ?? false
        hotCornerBottomLeft = triggers.hotCornersEnabled["bottomLeft"] ?? false
        hotCornerBottomRight = triggers.hotCornersEnabled["bottomRight"] ?? false
        multitouchEnabled = triggers.multitouchGestureEnabled
        multitouchSensitivity = triggers.multitouchSensitivity

        customSources = model.customSources
        hiddenApps = model.hiddenApplicationIdentifiers.compactMap { identifier in
            guard let record = model.record(for: identifier) else { return nil }
            return (identifier, model.displayName(for: record))
        }

        uninstallCandidates = model.allRecords
            .filter { !$0.isSystemProtected }
            .sorted { model.displayName(for: $0) < model.displayName(for: $1) }
    }

    /// Selects a candidate and recomputes its dry-run removal plan.
    public func selectUninstallCandidate(_ id: StableAppID) {
        selectedUninstallRecordID = id
        guard let record = model.record(for: id) else {
            uninstallPlan = []
            return
        }
        let evidence = OwnershipEvidenceCollector.collect(for: record)
        let siblings = model.allRecords.filter { $0.id != id }
        uninstallPlan = RemovalPlanner.plan(for: record, evidence: evidence, siblingRecords: siblings)
    }

    /// Used when the Uninstall tab is opened from a grid item's context
    /// menu — preselects that app instead of leaving the picker empty.
    public func preselectUninstallCandidate(bundleIdentifier: String) {
        selectedTab = .uninstall
        guard let record = uninstallCandidates.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        selectUninstallCandidate(record.id)
    }

    /// Saves the current dry-run plan as an `OperationReport` — a record of
    /// what *would* happen, since this phase never executes removals.
    public func saveUninstallDryRunReport() {
        guard let id = selectedUninstallRecordID, let record = model.record(for: id) else { return }
        let plan = uninstallPlan
        let bundleIdentifier = record.bundleIdentifier
        let store = reportStore
        Task {
            let report = OperationReport(bundleIdentifier: bundleIdentifier, generatedAt: Date(), plan: plan)
            _ = try? await store.save(report)
        }
    }

    public func saveGridSettings() {
        var grid = model.gridSettings
        grid.columns = columns
        grid.rows = rows
        grid.iconSize = iconSize
        model.updateGridSettings(grid)
        model.setLayoutMode(layoutMode)
        persist()
    }

    public func saveTriggerSettings() {
        var triggers = model.triggerSettings
        triggers.f4Enabled = f4Enabled
        triggers.hotkeyEnabled = hotkeyEnabled
        triggers.hotCornersEnabled = [
            "topLeft": hotCornerTopLeft,
            "topRight": hotCornerTopRight,
            "bottomLeft": hotCornerBottomLeft,
            "bottomRight": hotCornerBottomRight
        ]
        triggers.multitouchGestureEnabled = multitouchEnabled
        triggers.multitouchSensitivity = multitouchSensitivity
        model.updateTriggerSettings(triggers)
        persist()
        onTriggerSettingsChanged()
    }

    public func addCustomSource(path: String) {
        let config = CustomSourceConfig(
            id: UUID().uuidString,
            rootPath: path,
            recursive: true,
            includeGlobs: [],
            excludeGlobs: [],
            priority: 30,
            enabled: true
        )
        model.addCustomSource(config)
        customSources = model.customSources
        persist()
    }

    public func removeCustomSource(id: String) {
        model.removeCustomSource(id: id)
        customSources = model.customSources
        persist()
    }

    public func displayName(for record: ApplicationRecord) -> String {
        model.displayName(for: record)
    }

    public func unhide(_ identifier: StableAppIdentifier) {
        model.unhideApplication(identifier)
        hiddenApps.removeAll { $0.identifier == identifier }
        persist()
    }

    private func persist() {
        Task { await model.save() }
    }
}
