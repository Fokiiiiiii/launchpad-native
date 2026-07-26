import Catalog
import Foundation
import Grid
import Persistence

/// Renamed/regrouped to mirror a reference app's General/Screen/Apps/
/// Advanced/About tab structure: `general` holds what used to be the
/// standalone Triggers tab (launch methods), `screen` holds what used to
/// be the Grid tab (layout/sizing) plus newer display-related controls,
/// `apps` holds what used to be the Hidden tab, and `advanced` now shows
/// only the custom-sources form (the Uninstall feature that used to share
/// this tab behind a segmented sub-picker was removed at the user's
/// explicit request — Settings should not surface file deletion).
public enum SettingsTab: Hashable, Sendable {
    case general, screen, apps, advanced, about
}

/// Bridges `GridModel` (a plain `@MainActor` class, not `ObservableObject`)
/// into SwiftUI's `@Published` world. Every control applies live — no
/// "Apply" button anywhere (removed at the user's request: staged edit
/// buffers behind two separate Apply buttons meant most controls looked
/// inert until pressed, which read as "changing icon size does nothing").
/// Each property's `didSet` writes straight through to `GridModel` and
/// persists immediately, the same pattern this file already used for
/// `sortMode`/`hideDockWhileLauncherOpen` before this round.
@MainActor
public final class SettingsViewModel: ObservableObject {
    private let model: GridModel
    private let onTriggerSettingsChanged: () -> Bool
    private let onDockVisibilityChanged: (Bool) -> Void
    private var iconSizePersistWorkItem: DispatchWorkItem?

    @Published public var selectedTab: SettingsTab = .general
    @Published public var columns: Int {
        didSet {
            guard columns != oldValue else { return }
            applyGridDimensions()
            persist()
        }
    }
    @Published public var rows: Int {
        didSet {
            guard rows != oldValue else { return }
            applyGridDimensions()
            persist()
        }
    }
    /// Live-applies on every slider tick (so dragging visibly resizes the
    /// grid immediately), but debounces the disk write ~0.3s after the
    /// user stops moving it — a continuous slider drag firing dozens of
    /// `didSet`s a second shouldn't turn into dozens of `layout.json`
    /// writes a second.
    @Published public var iconSize: Double {
        didSet {
            guard iconSize != oldValue else { return }
            applyGridDimensions()
            scheduleIconSizePersist()
        }
    }
    @Published public var layoutMode: LayoutMode {
        didSet {
            guard layoutMode != oldValue else { return }
            model.setLayoutMode(layoutMode)
            persist()
        }
    }
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
    @Published public var appIconStyle: AppIconStyle {
        didSet {
            guard appIconStyle != oldValue else { return }
            model.setAppIconStyle(appIconStyle)
            AppIconStyleApplier.apply(appIconStyle)
            persist()
        }
    }

    @Published public var f4Enabled: Bool {
        didSet {
            guard f4Enabled != oldValue else { return }
            applyTriggerSettings()
        }
    }
    /// Whether F4 is actually registered right now — distinct from
    /// `f4Enabled` (what the user asked for). Refreshed whenever triggers
    /// are (re)applied, so the Triggers tab can show a real permission
    /// hint instead of just trusting the toggle.
    @Published public var f4Active: Bool = false
    @Published public var hotkeyEnabled: Bool {
        didSet {
            guard hotkeyEnabled != oldValue else { return }
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
            applyTriggerSettings()
        }
    }
    @Published public var hotCornerTopRight: Bool {
        didSet {
            guard hotCornerTopRight != oldValue else { return }
            applyTriggerSettings()
        }
    }
    @Published public var hotCornerBottomLeft: Bool {
        didSet {
            guard hotCornerBottomLeft != oldValue else { return }
            applyTriggerSettings()
        }
    }
    @Published public var hotCornerBottomRight: Bool {
        didSet {
            guard hotCornerBottomRight != oldValue else { return }
            applyTriggerSettings()
        }
    }
    @Published public var multitouchEnabled: Bool {
        didSet {
            guard multitouchEnabled != oldValue else { return }
            applyTriggerSettings()
        }
    }
    @Published public var multitouchSensitivity: Double {
        didSet {
            guard multitouchSensitivity != oldValue else { return }
            applyTriggerSettings()
        }
    }
    @Published public var multitouchFingerCount: Int {
        didSet {
            guard multitouchFingerCount != oldValue else { return }
            applyTriggerSettings()
        }
    }

    @Published public var customSources: [CustomSourceConfig]
    @Published public var hiddenApps: [(identifier: StableAppIdentifier, name: String)]

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
        appIconStyle = model.appIconStyle

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
    }

    private func applyGridDimensions() {
        var grid = model.gridSettings
        grid.columns = columns
        grid.rows = rows
        grid.iconSize = iconSize
        model.updateGridSettings(grid)
    }

    private func scheduleIconSizePersist() {
        iconSizePersistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.persist() }
        iconSizePersistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    /// Repacks every page tightly under the *current* grid settings — a
    /// manual one-shot action (unlike Sort By/Hide Dock, there's no
    /// toggled state to keep in sync with, so this isn't a `@Published`
    /// property).
    public func reorganizePages() {
        model.reorganizePages()
        persist()
    }

    private func applyTriggerSettings() {
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
