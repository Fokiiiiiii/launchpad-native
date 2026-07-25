import Catalog
import Foundation
import Grid
import Persistence
import Uninstall

/// Renamed/regrouped to mirror a reference app's General/Screen/Apps/
/// Advanced/About tab structure (user-confirmed mapping): `general` holds
/// what used to be the standalone Triggers tab (launch methods), `screen`
/// holds what used to be the Grid tab (layout/sizing) plus newer display-
/// related controls, `apps` holds what used to be the Hidden tab, and
/// `advanced` merges the old Sources and Uninstall tabs behind
/// `AdvancedSubTab` rather than a 6th top-level tab.
public enum SettingsTab: Hashable, Sendable {
    case general, screen, apps, advanced, about
}

/// Which of the two sub-sections `advanced` is currently showing —
/// Sources and Uninstall keep their own distinct view structures (a plain
/// form vs. a master-detail list) rather than being merged into one view.
public enum AdvancedSubTab: Hashable, Sendable {
    case sources, uninstall
}

/// Bridges `GridModel` (a plain `@MainActor` class, not `ObservableObject`)
/// into SwiftUI's `@Published` world. Mutations write straight through to
/// `GridModel` and persist immediately — there's no separate "unsaved
/// changes" state to reason about.
@MainActor
public final class SettingsViewModel: ObservableObject {
    private let model: GridModel
    private let onTriggerSettingsChanged: () -> Bool
    private let onDockVisibilityChanged: (Bool) -> Void

    @Published public var selectedTab: SettingsTab = .general
    @Published public var advancedSubTab: AdvancedSubTab = .sources
    @Published public var columns: Int
    @Published public var rows: Int
    @Published public var iconSize: Double
    @Published public var layoutMode: LayoutMode
    @Published public var sortMode: SortMode {
        didSet {
            guard sortMode != oldValue else { return }
            model.applySortMode(sortMode)
            persist()
        }
    }
    @Published public var hideDockWhileLauncherOpen: Bool {
        didSet {
            guard hideDockWhileLauncherOpen != oldValue else { return }
            onDockVisibilityChanged(hideDockWhileLauncherOpen)
        }
    }

    @Published public var f4Enabled: Bool
    /// Whether F4 is actually registered right now — distinct from
    /// `f4Enabled` (what the user asked for). Refreshed whenever triggers
    /// are (re)applied, so the Triggers tab can show a real permission
    /// hint instead of just trusting the toggle.
    @Published public var f4Active: Bool = false
    @Published public var hotkeyEnabled: Bool
    @Published public var hotkeyKeyCode: UInt16?
    @Published public var hotkeyCarbonModifiers: UInt
    @Published public var hotCornerTopLeft: Bool
    @Published public var hotCornerTopRight: Bool
    @Published public var hotCornerBottomLeft: Bool
    @Published public var hotCornerBottomRight: Bool
    @Published public var multitouchEnabled: Bool
    @Published public var multitouchSensitivity: Double
    @Published public var multitouchFingerCount: Int

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

    public init(model: GridModel, onTriggerSettingsChanged: @escaping () -> Bool, onDockVisibilityChanged: @escaping (Bool) -> Void) {
        self.model = model
        self.onTriggerSettingsChanged = onTriggerSettingsChanged
        self.onDockVisibilityChanged = onDockVisibilityChanged

        let grid = model.gridSettings
        columns = grid.columns
        rows = grid.rows
        iconSize = grid.iconSize
        layoutMode = model.layoutMode
        sortMode = grid.sortMode
        hideDockWhileLauncherOpen = model.hideDockWhileLauncherOpen

        let triggers = model.triggerSettings
        f4Enabled = triggers.f4Enabled
        hotkeyEnabled = triggers.hotkeyEnabled
        hotkeyKeyCode = triggers.hotkeyKeyCode
        hotkeyCarbonModifiers = triggers.hotkeyModifierFlags
        hotCornerTopLeft = triggers.hotCornersEnabled["topLeft"] ?? false
        hotCornerTopRight = triggers.hotCornersEnabled["topRight"] ?? false
        hotCornerBottomLeft = triggers.hotCornersEnabled["bottomLeft"] ?? false
        hotCornerBottomRight = triggers.hotCornersEnabled["bottomRight"] ?? false
        multitouchEnabled = triggers.multitouchGestureEnabled
        multitouchSensitivity = triggers.multitouchSensitivity
        multitouchFingerCount = triggers.multitouchFingerCount

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
        selectedTab = .advanced
        advancedSubTab = .uninstall
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

    /// The subset of the current plan this phase is willing to act on —
    /// `owned` and not needing a Privileged Helper. Everything else
    /// (`sharedRisk`, `unknown`, privileged items) is only ever displayed,
    /// never passed to a confirmation dialog as something that will happen.
    public var itemsEligibleForRemoval: [RemovalItem] {
        uninstallPlan.filter { $0.classification == .owned && !$0.requiresPrivilegedHelper }
    }

    /// Actually moves `itemsEligibleForRemoval` to the Trash (never a
    /// permanent delete) and terminates the app first if it's running.
    /// The caller (the view) is responsible for confirming with the user
    /// before invoking this — this method itself performs no confirmation.
    public func executeOwnedRemoval() {
        guard let id = selectedUninstallRecordID, let record = model.record(for: id) else { return }
        let bundleIdentifier = record.bundleIdentifier
        let store = reportStore

        RemovalExecutor.terminateIfRunning(bundleIdentifier: bundleIdentifier)
        let outcomes = RemovalExecutor.execute(uninstallPlan)

        Task {
            try? await store.recordExecution(bundleIdentifier: bundleIdentifier, outcomes: outcomes)
        }

        // Recompute the plan so the UI reflects what's actually left on
        // disk (trashed items no longer show up as `exists`).
        selectUninstallCandidate(id)
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

    /// Repacks every page tightly under the *current* grid settings — a
    /// manual one-shot action (unlike Sort By/Hide Dock, there's no
    /// toggled state to keep in sync with, so this isn't a `@Published`
    /// property).
    public func reorganizePages() {
        model.reorganizePages()
        persist()
    }

    public func saveTriggerSettings() {
        var triggers = model.triggerSettings
        triggers.f4Enabled = f4Enabled
        triggers.hotkeyEnabled = hotkeyEnabled
        triggers.hotkeyKeyCode = hotkeyKeyCode
        triggers.hotkeyModifierFlags = hotkeyCarbonModifiers
        triggers.hotCornersEnabled = [
            "topLeft": hotCornerTopLeft,
            "topRight": hotCornerTopRight,
            "bottomLeft": hotCornerBottomLeft,
            "bottomRight": hotCornerBottomRight
        ]
        triggers.multitouchGestureEnabled = multitouchEnabled
        triggers.multitouchSensitivity = multitouchSensitivity
        triggers.multitouchFingerCount = multitouchFingerCount
        model.updateTriggerSettings(triggers)
        persist()
        f4Active = onTriggerSettingsChanged()
    }

    /// Records a captured key combo from `HotkeyRecorderView` — stored but
    /// not yet applied until `saveTriggerSettings()` (matching every other
    /// control on this tab, which all require the "Apply" button).
    public func recordHotkey(keyCode: UInt16, carbonModifiers: UInt) {
        hotkeyKeyCode = keyCode
        hotkeyCarbonModifiers = carbonModifiers
    }

    /// Re-reads live trigger state without changing any setting — used when
    /// the Triggers tab first appears, so "F4 needs permission" reflects
    /// reality immediately rather than only after the user hits Apply once.
    public func refreshF4Status() {
        f4Active = onTriggerSettingsChanged()
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
