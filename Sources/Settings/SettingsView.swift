import AppKit
import Localization
import Persistence
import SwiftUI

public struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let onClose: () -> Void

    public init(viewModel: SettingsViewModel, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: $viewModel.selectedTab) {
                generalTab.tabItem { Label(L10n.tabGeneral, systemImage: "gearshape") }.tag(SettingsTab.general)
                screenTab.tabItem { Label(L10n.tabScreen, systemImage: "macwindow") }.tag(SettingsTab.screen)
                appsTab.tabItem { Label(L10n.tabApps, systemImage: "app.badge") }.tag(SettingsTab.apps)
                advancedTab.tabItem { Label(L10n.tabAdvanced, systemImage: "slider.horizontal.3") }.tag(SettingsTab.advanced)
                aboutTab.tabItem { Label(L10n.tabAbout, systemImage: "info.circle") }.tag(SettingsTab.about)
            }
            // Round 13 §A: the window's native titlebar/traffic-lights are
            // now fully hidden (see `SettingsWindowController`) to match the
            // reference's borderless floating-card look — this in-content
            // affordance is the only remaining *discoverable* way to close
            // Settings beyond clicking outside or pressing Escape.
            PanelCloseButton(action: onClose)
                .padding(12)
        }
        .background(.regularMaterial)
        .frame(width: 620, height: 600)
    }

    // MARK: Screen (was Grid)

    private var screenTab: some View {
        Form {
            Section {
                Picker(L10n.layoutPickerLabel, selection: $viewModel.layoutMode) {
                    Text(L10n.layoutModePaged).tag(LayoutMode.paged)
                    Text(L10n.layoutModeVerticalScroll).tag(LayoutMode.verticalScroll)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
            } header: {
                Label(L10n.layoutPickerLabel, systemImage: "rectangle.3.group")
                    .foregroundStyle(.blue)
            }

            Section {
                Stepper(value: $viewModel.columns, in: 3...12) {
                    Label(L10n.columnsLabel(viewModel.columns), systemImage: "rectangle.grid.2x2")
                }
                Stepper(value: $viewModel.rows, in: 2...8) {
                    Label(L10n.rowsLabel(viewModel.rows), systemImage: "rectangle.grid.1x2")
                }
            } header: {
                Label(L10n.tabGrid, systemImage: "square.grid.3x3.fill")
                    .foregroundStyle(.blue)
            }

            Section {
                Picker(selection: $viewModel.sortMode) {
                    Text(L10n.sortModeCustom).tag(SortMode.custom)
                    Text(L10n.sortModeName).tag(SortMode.name)
                    Text(L10n.sortModeDateAdded).tag(SortMode.dateAdded)
                    Text(L10n.sortModeLastUsed).tag(SortMode.lastUsed)
                } label: {
                    Label(L10n.sortByLabel, systemImage: "arrow.up.arrow.down")
                }
                .pickerStyle(.radioGroup)

                HStack {
                    Spacer()
                    Button {
                        viewModel.reorganizePages()
                    } label: {
                        Label(L10n.reorganizeButton, systemImage: "square.grid.3x2.fill")
                    }
                }

                Toggle(isOn: $viewModel.hideDockWhileLauncherOpen) {
                    Label(L10n.hideDockToggleLabel, systemImage: "dock.rectangle")
                }
            } header: {
                Label(L10n.displaySectionHeader, systemImage: "macwindow.badge.plus")
                    .foregroundStyle(.blue)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: General (was Triggers)

    private var generalTab: some View {
        Form {
            Section {
                Toggle(isOn: $viewModel.f4Enabled) {
                    Label(L10n.f4ToggleLabel, systemImage: "keyboard")
                }
                if viewModel.f4Enabled && !viewModel.f4Active {
                    f4PermissionHint
                }

                Toggle(isOn: $viewModel.hotkeyEnabled) {
                    Label(L10n.globalHotkeyToggleLabel, systemImage: "command")
                }
                if viewModel.hotkeyEnabled {
                    HotkeyRecorderView(
                        keyCode: $viewModel.hotkeyKeyCode,
                        carbonModifiers: $viewModel.hotkeyCarbonModifiers,
                        onCommit: { keyCode, modifiers in viewModel.recordHotkey(keyCode: keyCode, carbonModifiers: modifiers) }
                    )
                    .frame(width: 160, height: 24)
                }
            } header: {
                Label(L10n.tabTriggers, systemImage: "hand.tap.fill")
                    .foregroundStyle(.orange)
            }

            Section {
                Toggle(isOn: $viewModel.hotCornerTopLeft) {
                    Label(L10n.hotCornerTopLeft, systemImage: "arrow.up.left.square")
                }
                Toggle(isOn: $viewModel.hotCornerTopRight) {
                    Label(L10n.hotCornerTopRight, systemImage: "arrow.up.right.square")
                }
                Toggle(isOn: $viewModel.hotCornerBottomLeft) {
                    Label(L10n.hotCornerBottomLeft, systemImage: "arrow.down.left.square")
                }
                Toggle(isOn: $viewModel.hotCornerBottomRight) {
                    Label(L10n.hotCornerBottomRight, systemImage: "arrow.down.right.square")
                }
            } header: {
                Label(L10n.hotCornersGroupTitle, systemImage: "rectangle.inset.filled")
                    .foregroundStyle(.orange)
            }

            Section {
                Toggle(isOn: $viewModel.multitouchEnabled) {
                    Label(L10n.multitouchToggleLabel, systemImage: "hand.draw")
                }
                Picker(selection: $viewModel.multitouchFingerCount) {
                    Text(L10n.fingerCountFour).tag(4)
                    Text(L10n.fingerCountFive).tag(5)
                } label: {
                    Label(L10n.fingerCountLabel, systemImage: "hand.raised.fingers.spread")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.sensitivityLabel, systemImage: "dial.medium")
                    Slider(value: $viewModel.multitouchSensitivity, in: 0.3...0.8)
                        .accessibilityLabel(L10n.gestureSensitivityAccessibilityLabel)
                }
                if viewModel.multitouchEnabled {
                    Toggle(isOn: $viewModel.gestureConflictPreventionEnabled) {
                        Label(L10n.gestureConflictPreventionToggleLabel, systemImage: "shield.lefthalf.filled")
                    }
                    gestureConflictHint
                }
            } header: {
                Label(L10n.trackpadGestureGroupTitle, systemImage: "hand.point.up.braille")
                    .foregroundStyle(.orange)
            }

            Section {
                HStack(spacing: 16) {
                    ForEach(AppIconStyle.allCases, id: \.self) { style in
                        Button {
                            viewModel.appIconStyle = style
                        } label: {
                            VStack(spacing: 6) {
                                Image(nsImage: AppIconStyleApplier.previewImage(for: style) ?? NSImage())
                                    .resizable()
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .strokeBorder(viewModel.appIconStyle == style ? Color.accentColor : .clear, lineWidth: 2)
                                    )
                                Text(displayName(for: style))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(L10n.appIconLimitedEffectNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label(L10n.appIconSectionHeader, systemImage: "app.badge")
                    .foregroundStyle(.purple)
            }
        }
        .formStyle(.grouped)
    }

    private func displayName(for style: AppIconStyle) -> String {
        switch style {
        case .classic: L10n.appIconStyleClassic
        case .monochrome: L10n.appIconStyleMonochrome
        case .solid: L10n.appIconStyleSolid
        case .diagonal: L10n.appIconStyleDiagonal
        }
    }

    /// Shown only when F4 is turned on but genuinely isn't working — this
    /// app bundle needs Input Monitoring permission for the CGEventTap F4
    /// relies on, which macOS never grants automatically. Without this,
    /// the toggle silently does nothing and looks like a bug.
    private var f4PermissionHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.f4PermissionHint)
                    .font(.caption)
                Button(L10n.openPrivacySettingsButton) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption)
            }
        }
    }

    /// Shown whenever the gesture is turned on — not conditioned on
    /// detecting an actual conflict (there's no public API to introspect
    /// the system's own trackpad gesture assignments), since real hands-on
    /// testing found this gesture collides with macOS's own default
    /// Launchpad/Mission Control trackpad assignment often enough that a
    /// standing warning is more honest than a one-time toggle. Switches to
    /// a success-styled message once the auto-prevention toggle above is
    /// on — worded carefully ("has told macOS," not "has disabled") since
    /// whether the OS actually stops recognizing the gesture without a
    /// logout is a disclosed, unverified uncertainty (see
    /// `Triggers.ConflictingGestureManager`'s doc comment).
    private var gestureConflictHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: viewModel.gestureConflictPreventionEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(viewModel.gestureConflictPreventionEnabled ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.gestureConflictPreventionEnabled ? L10n.gestureConflictPreventionActiveHint : L10n.gestureConflictHint)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.openTrackpadSettingsButton) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.trackpad") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption)
            }
        }
    }

    // MARK: Sources

    private var sourcesTab: some View {
        Form {
            Section {
                if viewModel.customSources.isEmpty {
                    Text(L10n.chooseFolderPanelMessage)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.customSources, id: \.id) { source in
                        HStack {
                            Label {
                                Text(source.rootPath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                viewModel.removeCustomSource(id: source.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button {
                        addFolder()
                    } label: {
                        Label(L10n.addFolderButton, systemImage: "plus.circle.fill")
                    }
                }
            } header: {
                Label(L10n.tabSources, systemImage: "folder.fill.badge.plus")
                    .foregroundStyle(.green)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Apps (was Hidden)

    private var appsTab: some View {
        Form {
            Section {
                if viewModel.hiddenApps.isEmpty {
                    Text(L10n.noHiddenAppsMessage)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.hiddenApps, id: \.identifier) { entry in
                        HStack {
                            Label(entry.name, systemImage: "eye.slash.fill")
                            Spacer()
                            Button(L10n.unhideButton) { viewModel.unhide(entry.identifier) }
                        }
                    }
                }
            } header: {
                Label(L10n.tabHidden, systemImage: "eye.slash.circle.fill")
                    .foregroundStyle(.gray)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Advanced (Sources only — the Uninstall feature that used to
    // share this tab behind a segmented sub-picker was removed at the
    // user's explicit request; Settings should not surface file deletion)

    private var advancedTab: some View {
        sourcesTab
    }

    /// App identity + license only — deliberately no credits/contributor
    /// list. There wasn't one before this tab existed, and none is added
    /// now.
    private var aboutTab: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(nsImage: AppIconStyleApplier.previewImage(for: viewModel.appIconStyle) ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text(Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "LaunchpadNative")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(L10n.aboutVersionLabel(
                    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—",
                    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                Label(L10n.aboutLicenseLabel, systemImage: "doc.text")
                Label(L10n.aboutOpenSourceLabel, systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.chooseFolderPanelMessage
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.addCustomSource(path: url.path)
        }
    }
}
