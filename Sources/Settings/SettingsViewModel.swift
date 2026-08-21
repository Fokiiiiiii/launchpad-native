import Catalog
import Diagnostics
import Foundation
import Grid
import Persistence
import ServiceManagement

public enum SettingsTab: Hashable, Sendable {
    case general, screen, apps, advanced, about
}

public enum GestureConflictApplyStatus: Sendable, Equatable {
    case unchanged
    case applied
    case restored
    case failed
}

public struct TriggerSettingsApplyResult: Sendable, Equatable {
    public let f4Active: Bool
    public let multitouchActive: Bool
    public let multitouchEventArbitrationActive: Bool
    public let gestureConflictStatus: GestureConflictApplyStatus
    public let gestureConflictBackup: GestureConflictBackup?

    public init(
        f4Active: Bool,
        multitouchActive: Bool,
        multitouchEventArbitrationActive: Bool,
        gestureConflictStatus: GestureConflictApplyStatus,
        gestureConflictBackup: GestureConflictBackup?
    ) {
        self.f4Active = f4Active
        self.multitouchActive = multitouchActive
        self.multitouchEventArbitrationActive = multitouchEventArbitrationActive
        self.gestureConflictStatus = gestureConflictStatus
        self.gestureConflictBackup = gestureConflictBackup
    }

    public static let failed = TriggerSettingsApplyResult(
        f4Active: false,
        multitouchActive: false,
        multitouchEventArbitrationActive: false,
        gestureConflictStatus: .failed,
        gestureConflictBackup: nil
    )
}

/// SwiftUI settings bridge for the main-actor grid model.
@MainActor
public final class SettingsViewModel: ObservableObject {
    private let model: GridModel
    private let onTriggerSettingsChanged: (TriggerSettings) async -> TriggerSettingsApplyResult
    private let onDockVisibilityChanged: (Bool) -> Void
    private let onShowsMenuBarIconChanged: (Bool) -> Void
    private let onAppIconStyleChanged: (AppIconStyle) -> Void
    private let onShowsHiddenAppsInSearchChanged: () -> Void
    private let onMenuBarApplicationsChanged: () -> Void
    private let onBackgroundSettingsChanged: () -> Void
    private let onCustomSourcesChanged: () -> Void
    private var isRollingBackLaunchAtLogin = false
    private var isRefreshing = false
    private var triggerApplyTask: Task<Void, Never>?
    private var triggerApplyOwnerGeneration: UInt?
    private var triggerApplyGeneration: UInt = 0
    private var pendingTriggerSettings: TriggerSettings?
    private var backgroundPersistTask: Task<Void, Never>?
    private var backgroundPersistGeneration: UInt = 0
    private var gridPersistTask: Task<Void, Never>?
    private var gridPersistGeneration: UInt = 0
    private var isEditingGlassMaterial = false

    @Published public var selectedTab: SettingsTab = .general
    @Published public var columns: Int {
        didSet {
            guard columns != oldValue else { return }
            guard !isRefreshing else { return }
            applyGridDimensions()
            persistGrid()
        }
    }
    @Published public var rows: Int {
        didSet {
            guard rows != oldValue else { return }
            guard !isRefreshing else { return }
            applyGridDimensions()
            persistGrid()
        }
    }
    @Published public var horizontalSpacing: Double {
        didSet {
            guard horizontalSpacing != oldValue else { return }
            guard !isRefreshing else { return }
            applyGridDimensions()
            persistGrid()
        }
    }
    @Published public var verticalSpacing: Double {
        didSet {
            guard verticalSpacing != oldValue else { return }
            guard !isRefreshing else { return }
            applyGridDimensions()
            persistGrid()
        }
    }
    @Published public var pageMargins: Double {
        didSet {
            guard pageMargins != oldValue else { return }
            guard !isRefreshing else { return }
            applyGridDimensions()
            persistGrid()
        }
    }
    /// Persisted icon multiplier, intentionally independent from columns and
    /// rows. Manual edits are represented as `.custom`; selecting a preset
    /// changes this value only and never changes grid capacity.
    @Published public var iconScale: Double {
        didSet {
            guard iconScale != oldValue else { return }
            guard !isRefreshing else { return }
            guard !isApplyingIconScalePreset else { return }
            var grid = model.gridSettings
            grid.iconScale = iconScale
            model.updateGridSettings(grid)
            iconScalePreset = .custom
            persist()
        }
    }
    @Published public private(set) var iconScalePreset: GridIconScalePreset = .custom
    private var isApplyingIconScalePreset = false

    @Published public var layoutMode: LayoutMode {
        didSet {
            guard layoutMode != oldValue else { return }
            guard !isRefreshing else { return }
            model.setLayoutMode(layoutMode)
            persist()
        }
    }
    @Published public var sortMode: SortMode {
        didSet {
            guard sortMode != oldValue else { return }
            guard !isRefreshing else { return }
            model.applySortMode(sortMode)
            persist()
        }
    }
    @Published public var hideDockWhileLauncherOpen: Bool {
        didSet {
            guard hideDockWhileLauncherOpen != oldValue else { return }
            guard !isRefreshing else { return }
            onDockVisibilityChanged(hideDockWhileLauncherOpen)
        }
    }
    @Published public var appIconStyle: AppIconStyle {
        didSet {
            guard appIconStyle != oldValue else { return }
            guard !isRefreshing else { return }
            model.setAppIconStyle(appIconStyle)
            AppIconStyleApplier.apply(appIconStyle)
            onAppIconStyleChanged(appIconStyle)
            persist()
        }
    }

    /// State lives in `SMAppService.mainApp.status`, not `LayoutDocument` —
    /// same "OS is the source of truth, this property just reflects it"
    /// pattern as `f4Active` below, not a persisted preference of our own.
    @Published public var launchAtLoginEnabled: Bool {
        didSet {
            guard !isRollingBackLaunchAtLogin, launchAtLoginEnabled != oldValue else { return }
            guard !isRefreshing else { return }
            do {
                if launchAtLoginEnabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                DiagnosticsLog.settings.error("SMAppService \(self.launchAtLoginEnabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                // ServiceManagement is the source of truth. If the OS rejects
                // the request (for example, an unsigned debug build), restore
                // the previous value so the toggle never claims a state that
                // was not actually applied.
                isRollingBackLaunchAtLogin = true
                launchAtLoginEnabled = oldValue
                isRollingBackLaunchAtLogin = false
            }
        }
    }
    @Published public var showsMenuBarIcon: Bool {
        didSet {
            guard showsMenuBarIcon != oldValue else { return }
            guard !isRefreshing else { return }
            model.setShowsMenuBarIcon(showsMenuBarIcon)
            onShowsMenuBarIconChanged(showsMenuBarIcon)
            persist()
        }
    }
    @Published public var showsHiddenAppsInSearch: Bool {
        didSet {
            guard showsHiddenAppsInSearch != oldValue else { return }
            guard !isRefreshing else { return }
            model.setShowsHiddenAppsInSearch(showsHiddenAppsInSearch)
            onShowsHiddenAppsInSearchChanged()
            persist()
        }
    }
    @Published public var showMenuBarApplications: Bool {
        didSet {
            guard showMenuBarApplications != oldValue else { return }
            guard !isRefreshing else { return }
            model.setShowMenuBarApplications(showMenuBarApplications)
            onMenuBarApplicationsChanged()
            persist()
        }
    }
    @Published public var backgroundMode: LauncherBackgroundMode {
        didSet {
            guard backgroundMode != oldValue else { return }
            guard !isRefreshing else { return }
            model.setBackgroundMode(backgroundMode)
            onBackgroundSettingsChanged()
            persistBackgroundSettings()
        }
    }
    @Published public var glassMaterialIntensity: Double {
        didSet {
            guard glassMaterialIntensity != oldValue else { return }
            guard !isRefreshing else { return }
            model.setGlassMaterialIntensity(glassMaterialIntensity)
            onBackgroundSettingsChanged()
            if !isEditingGlassMaterial {
                persistBackgroundSettings()
            }
        }
    }
    @Published public var blursWallpaper: Bool {
        didSet {
            guard blursWallpaper != oldValue else { return }
            guard !isRefreshing else { return }
            model.setBlursWallpaper(blursWallpaper)
            onBackgroundSettingsChanged()
            persistBackgroundSettings()
        }
    }

    @Published public var f4Enabled: Bool {
        didSet {
            guard f4Enabled != oldValue else { return }
            guard !isRefreshing else { return }
            applyTriggerSettings()
        }
    }
    /// Whether F4 is actually registered right now — distinct from
    /// `f4Enabled` (what the user asked for). Refreshed whenever triggers
    /// are (re)applied, so the Triggers tab can show a real permission
    /// hint instead of just trusting the toggle.
    @Published public var f4Active: Bool = false
    @Published public private(set) var multitouchActive: Bool = false
    @Published public var multitouchEventArbitrationActive: Bool = false
    @Published public private(set) var gestureConflictStatus: GestureConflictApplyStatus = .unchanged
    @Published public var hotkeyEnabled: Bool {
        didSet {
            guard hotkeyEnabled != oldValue else { return }
            guard !isRefreshing else { return }
            applyTriggerSettings()
        }
    }
    /// No `didSet` here deliberately — `HotkeyRecorderView` writes
    /// `hotkeyKeyCode` and `hotkeyCarbonModifiers` one after the other when
    /// a combo is captured. If either had its own live-apply `didSet`,
    /// the first write would briefly register a half-formed combo (new
    /// key, still-old modifiers) as the real global hotkey. `recordHotkey`
    /// below is the single commit point, called once after both bindings
    /// are already updated.
    @Published public var hotkeyKeyCode: UInt16?
    @Published public var hotkeyCarbonModifiers: UInt
    @Published public var hotCornerTopLeft: Bool {
        didSet {
            guard hotCornerTopLeft != oldValue else { return }
            guard !isRefreshing else { return }
            applyTriggerSettings()
        }
    }
    @Published public var hotCornerTopRight: Bool {
        didSet {
            guard hotCornerTopRight != oldValue else { return }
            guard !isRefreshing else { return }
            applyTriggerSettings()
        }
    }
    @Published public var hotCornerBottomLeft: Bool {
        didSet {
            guard hotCornerBottomLeft != oldValue else { return }
            guard !isRefreshing else { return }
            applyTriggerSettings()
        }
    }
    @Published public var hotCornerBottomRight: Bool {
        didSet {
            guard hotCornerBottomRight != oldValue else { return }
            guard !isRefreshing else { return }
            applyTriggerSettings()
        }
    }
    @Published public var multitouchEnabled: Bool {
        didSet {
            guard multitouchEnabled != oldValue else { return }
            guard !isRefreshing else { return }
            // A raw multitouch observer is passive, so its matching macOS
            // conflict policy follows this switch. The legacy published field
            // is kept only for persisted-data compatibility.
            if multitouchEnabled, !gestureConflictPreventionEnabled {
                gestureConflictPreventionEnabled = true
            } else {
                applyTriggerSettings()
            }
        }
    }
    @Published public var multitouchSensitivity: Double {
        didSet {
            guard multitouchSensitivity != oldValue else { return }
            guard !isRefreshing else { return }
            applyTriggerSettings()
        }
    }
    @Published public var multitouchFingerCount: Int {
        didSet {
            guard multitouchFingerCount != oldValue else { return }
            guard !isRefreshing else { return }
            applyTriggerSettings()
        }
    }
    /// Legacy persisted field retained for migration. Runtime conflict
    /// suppression is owned by `multitouchEnabled` and the coordinator.
    @Published public var gestureConflictPreventionEnabled: Bool {
        didSet {
            guard gestureConflictPreventionEnabled != oldValue else { return }
            guard !isRefreshing else { return }
            applyTriggerSettings()
        }
    }

    @Published public var customSources: [CustomSourceConfig]
    @Published public var hiddenApps: [(identifier: StableAppIdentifier, name: String)]

    public init(
        model: GridModel,
        onTriggerSettingsChanged: @escaping (TriggerSettings) async -> TriggerSettingsApplyResult,
        onDockVisibilityChanged: @escaping (Bool) -> Void,
        onShowsMenuBarIconChanged: @escaping (Bool) -> Void = { _ in },
        onAppIconStyleChanged: @escaping (AppIconStyle) -> Void = { _ in },
        onShowsHiddenAppsInSearchChanged: @escaping () -> Void = {},
        onMenuBarApplicationsChanged: @escaping () -> Void = {},
        onBackgroundSettingsChanged: @escaping () -> Void = {},
        onCustomSourcesChanged: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onTriggerSettingsChanged = onTriggerSettingsChanged
        self.onDockVisibilityChanged = onDockVisibilityChanged
        self.onShowsMenuBarIconChanged = onShowsMenuBarIconChanged
        self.onAppIconStyleChanged = onAppIconStyleChanged
        self.onShowsHiddenAppsInSearchChanged = onShowsHiddenAppsInSearchChanged
        self.onMenuBarApplicationsChanged = onMenuBarApplicationsChanged
        self.onBackgroundSettingsChanged = onBackgroundSettingsChanged
        self.onCustomSourcesChanged = onCustomSourcesChanged

        let grid = model.gridSettings
        columns = grid.columns
        rows = grid.rows
        horizontalSpacing = grid.horizontalSpacing
        verticalSpacing = grid.verticalSpacing
        pageMargins = grid.pageMargins
        iconScale = grid.iconScale
        iconScalePreset = GridIconScalePreset.matching(grid)
        layoutMode = model.layoutMode == .verticalScroll ? .paged : model.layoutMode
        if model.layoutMode == .verticalScroll {
            model.setLayoutMode(.paged)
        }
        sortMode = grid.sortMode
        hideDockWhileLauncherOpen = model.hideDockWhileLauncherOpen
        appIconStyle = model.appIconStyle
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        showsMenuBarIcon = model.showsMenuBarIcon
        showMenuBarApplications = model.showMenuBarApplications
        showsHiddenAppsInSearch = model.showsHiddenAppsInSearch
        backgroundMode = model.backgroundMode
        glassMaterialIntensity = model.glassMaterialIntensity
        blursWallpaper = model.blursWallpaper

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
        gestureConflictPreventionEnabled = triggers.gestureConflictPreventionEnabled

        customSources = model.customSources
        hiddenApps = model.hiddenApplicationIdentifiers.compactMap { identifier in
            guard let record = model.record(for: identifier) else { return nil }
            return (identifier, model.displayName(for: record))
        }
    }

    private func applyGridDimensions() {
        var grid = model.gridSettings
        grid.columns = columns
        grid.rows = rows
        grid.horizontalSpacing = horizontalSpacing
        grid.verticalSpacing = verticalSpacing
        grid.pageMargins = pageMargins

        let selectedIconScalePreset = iconScalePreset
        if selectedIconScalePreset == .smart,
           let recommendedScale = GridIconScalePreset.smart.scale(
               columns: grid.columns,
               rows: grid.rows
           ) {
            grid.iconScale = recommendedScale
            isApplyingIconScalePreset = true
            iconScale = recommendedScale
            isApplyingIconScalePreset = false
        }

        model.updateGridSettings(grid)
        iconScalePreset = selectedIconScalePreset
    }

    /// Applies an icon-size choice while keeping the current grid geometry and
    /// page capacity intact. Smart resolves against the current columns × rows
    /// and can optionally use a cell-size hint supplied by a future live UI.
    public func applyIconScalePreset(
        _ preset: GridIconScalePreset,
        availableCellSize: CGSize? = nil
    ) {
        guard preset != .custom else { return }
        let grid = preset.applying(
            to: model.gridSettings,
            availableCellSize: availableCellSize
        )
        isApplyingIconScalePreset = true
        iconScale = grid.iconScale
        isApplyingIconScalePreset = false
        model.updateGridSettings(grid)
        iconScalePreset = preset
        persist()
    }

    public func reorganizePages() {
        model.reorganizePages()
        persist()
    }

    private func applyTriggerSettings() {
        pendingTriggerSettings = triggerSettingsFromControls()
        triggerApplyGeneration &+= 1
        guard triggerApplyTask == nil else { return }

        let ownerGeneration = triggerApplyGeneration
        triggerApplyOwnerGeneration = ownerGeneration
        triggerApplyTask = Task { @MainActor [weak self] in
            // Let a burst of didSet callbacks settle before beginning the
            // external transaction. This coalesces one UI edit without
            // adding an arbitrary delay to the trigger path.
            await Task.yield()
            guard let self else { return }
            defer {
                if self.triggerApplyOwnerGeneration == ownerGeneration {
                    self.triggerApplyTask = nil
                    self.triggerApplyOwnerGeneration = nil
                    if self.pendingTriggerSettings != nil {
                        self.applyTriggerSettings()
                    }
                }
            }

            let candidate = self.pendingTriggerSettings
            self.pendingTriggerSettings = nil
            guard let candidate else { return }

            let generation = self.triggerApplyGeneration
            let previous = self.model.triggerSettings
            let result = await self.onTriggerSettingsChanged(candidate)
            guard self.triggerApplyGeneration == generation else {
                // A newer candidate superseded this transaction while the
                // external side effect was in flight. The callback owns its
                // own rollback; a subsequent didSet schedules the latest
                // candidate after this task completes.
                return
            }
            self.f4Active = result.f4Active
            self.multitouchActive = result.multitouchActive
            self.multitouchEventArbitrationActive = result.multitouchEventArbitrationActive
            self.gestureConflictStatus = result.gestureConflictStatus

            guard result.gestureConflictStatus != .failed else {
                // The callback owns the model/external rollback. Reflect that
                // transaction result in every trigger control, not only the
                // conflict toggle, so a failed durable save cannot leave a
                // partially applied UI candidate behind.
                self.restoreTriggerControls(from: previous)
                return
            }
        }
    }

    private func triggerSettingsFromControls() -> TriggerSettings {
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
        // Conflict suppression is part of the multitouch trigger transaction.
        // Keep the legacy field for Codable compatibility, but never allow a
        // stale opt-out to leave the standard gesture active while our trigger
        // is enabled.
        triggers.gestureConflictPreventionEnabled = multitouchEnabled
        return triggers
    }

    private func restoreTriggerControls(from settings: TriggerSettings) {
        isRefreshing = true
        defer { isRefreshing = false }
        f4Enabled = settings.f4Enabled
        hotkeyEnabled = settings.hotkeyEnabled
        hotkeyKeyCode = settings.hotkeyKeyCode
        hotkeyCarbonModifiers = settings.hotkeyModifierFlags
        hotCornerTopLeft = settings.hotCornersEnabled["topLeft"] ?? false
        hotCornerTopRight = settings.hotCornersEnabled["topRight"] ?? false
        hotCornerBottomLeft = settings.hotCornersEnabled["bottomLeft"] ?? false
        hotCornerBottomRight = settings.hotCornersEnabled["bottomRight"] ?? false
        multitouchEnabled = settings.multitouchGestureEnabled
        multitouchSensitivity = settings.multitouchSensitivity
        multitouchFingerCount = settings.multitouchFingerCount
        gestureConflictPreventionEnabled = settings.gestureConflictPreventionEnabled
    }

    /// Commits a captured key combo from `HotkeyRecorderView` — the single
    /// point where a hotkey change actually takes effect (see
    /// `hotkeyKeyCode`'s doc comment for why the properties themselves
    /// don't each have a live-apply `didSet`).
    public func recordHotkey(keyCode: UInt16, carbonModifiers: UInt) {
        hotkeyKeyCode = keyCode
        hotkeyCarbonModifiers = carbonModifiers
        applyTriggerSettings()
    }

    /// Re-reads live trigger state without changing any setting — used when
    /// the Triggers tab first appears, so "F4 needs permission" reflects
    /// reality immediately.
    public func refreshF4Status() {
        let prior = triggerApplyTask
        triggerApplyGeneration &+= 1
        let generation = triggerApplyGeneration
        triggerApplyOwnerGeneration = generation
        triggerApplyTask = Task { @MainActor [weak self] in
            await prior?.value
            guard let self else { return }
            let result = await self.onTriggerSettingsChanged(self.model.triggerSettings)
            if self.triggerApplyGeneration == generation {
                self.f4Active = result.f4Active
                self.multitouchActive = result.multitouchActive
                self.multitouchEventArbitrationActive = result.multitouchEventArbitrationActive
                self.gestureConflictStatus = result.gestureConflictStatus
            }
            // A control can change while the refresh transaction is in flight.
            // Always release this task and replay the newest pending candidate;
            // otherwise didSet sees a completed task and silently stops applying.
            guard self.triggerApplyOwnerGeneration == generation else { return }
            self.triggerApplyTask = nil
            self.triggerApplyOwnerGeneration = nil
            if self.pendingTriggerSettings != nil {
                self.applyTriggerSettings()
            }
        }
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
        onCustomSourcesChanged()
        persist()
    }

    public func removeCustomSource(id: String) {
        model.removeCustomSource(id: id)
        customSources = model.customSources
        onCustomSourcesChanged()
        persist()
    }

    public func displayName(for record: ApplicationRecord) -> String {
        model.displayName(for: record)
    }

    public func unhide(_ identifier: StableAppIdentifier) {
        model.unhideApplication(identifier)
        hiddenApps.removeAll { $0.identifier == identifier }
        onShowsHiddenAppsInSearchChanged()
        persist()
    }

    public func refresh() {
        isRefreshing = true
        defer { isRefreshing = false }

        let grid = model.gridSettings
        columns = grid.columns
        rows = grid.rows
        horizontalSpacing = grid.horizontalSpacing
        verticalSpacing = grid.verticalSpacing
        pageMargins = grid.pageMargins
        iconScale = grid.iconScale
        iconScalePreset = GridIconScalePreset.matching(grid)

        layoutMode = model.layoutMode == .verticalScroll ? .paged : model.layoutMode
        sortMode = grid.sortMode
        hideDockWhileLauncherOpen = model.hideDockWhileLauncherOpen
        appIconStyle = model.appIconStyle
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        showsMenuBarIcon = model.showsMenuBarIcon
        showMenuBarApplications = model.showMenuBarApplications
        showsHiddenAppsInSearch = model.showsHiddenAppsInSearch
        backgroundMode = model.backgroundMode
        glassMaterialIntensity = model.glassMaterialIntensity
        blursWallpaper = model.blursWallpaper

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
        gestureConflictPreventionEnabled = triggers.gestureConflictPreventionEnabled

        customSources = model.customSources
        hiddenApps = model.hiddenApplicationIdentifiers.compactMap { identifier in
            guard let record = model.record(for: identifier) else { return nil }
            return (identifier, model.displayName(for: record))
        }
        let prior = triggerApplyTask
        triggerApplyGeneration &+= 1
        let generation = triggerApplyGeneration
        triggerApplyOwnerGeneration = generation
        triggerApplyTask = Task { @MainActor [weak self] in
            await prior?.value
            guard let self else { return }
            let result = await self.onTriggerSettingsChanged(triggers)
            if self.triggerApplyGeneration == generation {
                self.f4Active = result.f4Active
                self.multitouchActive = result.multitouchActive
                self.multitouchEventArbitrationActive = result.multitouchEventArbitrationActive
                self.gestureConflictStatus = result.gestureConflictStatus
            }
            guard self.triggerApplyOwnerGeneration == generation else { return }
            self.triggerApplyTask = nil
            self.triggerApplyOwnerGeneration = nil
            if self.pendingTriggerSettings != nil {
                self.applyTriggerSettings()
            }
        }
    }

    /// Slider updates are intentionally live-only while the pointer is down;
    /// the final value is persisted once editing ends. This keeps rapid UI
    /// drags from queueing atomic layout writes behind one another.
    func setGlassMaterialEditing(_ editing: Bool) {
        isEditingGlassMaterial = editing
        if !editing {
            persistBackgroundSettings()
        }
    }

    private func persist() {
        Task { await model.save() }
    }

    private func persistGrid() {
        gridPersistGeneration &+= 1
        let generation = gridPersistGeneration
        gridPersistTask?.cancel()
        gridPersistTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.gridPersistGeneration == generation else { return }
            _ = await self.model.save()
            if self.gridPersistGeneration == generation {
                self.gridPersistTask = nil
            }
        }
    }

    private func persistBackgroundSettings() {
        backgroundPersistGeneration &+= 1
        let generation = backgroundPersistGeneration
        backgroundPersistTask?.cancel()
        backgroundPersistTask = Task { @MainActor [weak self] in
            // Coalesce values emitted by one Slider drag into the latest
            // configuration without introducing a wall-clock debounce.
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.backgroundPersistGeneration == generation else { return }
            _ = await self.model.save()
            if self.backgroundPersistGeneration == generation {
                self.backgroundPersistTask = nil
            }
        }
    }
}
