import AppKit
import Localization
import Persistence
import SwiftUI
import Uninstall

public struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        TabView(selection: $viewModel.selectedTab) {
            generalTab.tabItem { Label(L10n.tabGeneral, systemImage: "gearshape") }.tag(SettingsTab.general)
            screenTab.tabItem { Label(L10n.tabScreen, systemImage: "macwindow") }.tag(SettingsTab.screen)
            appsTab.tabItem { Label(L10n.tabApps, systemImage: "app.badge") }.tag(SettingsTab.apps)
            advancedTab.tabItem { Label(L10n.tabAdvanced, systemImage: "slider.horizontal.3") }.tag(SettingsTab.advanced)
            aboutTab.tabItem { Label(L10n.tabAbout, systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 620, height: 560)
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
            }

            Section {
                Stepper(value: $viewModel.columns, in: 3...12) {
                    Label(L10n.columnsLabel(viewModel.columns), systemImage: "rectangle.grid.2x2")
                }
                Stepper(value: $viewModel.rows, in: 2...8) {
                    Label(L10n.rowsLabel(viewModel.rows), systemImage: "rectangle.grid.1x2")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.iconSizeLabel(Int(viewModel.iconSize)), systemImage: "app.badge")
                    Slider(value: $viewModel.iconSize, in: 48...160)
                        .accessibilityLabel(L10n.iconSizeAccessibilityLabel)
                }
            } header: {
                Label(L10n.tabGrid, systemImage: "square.grid.3x3.fill")
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
                Label(L10n.sortByLabel, systemImage: "arrow.up.arrow.down.circle.fill")
            }

            Section {
                HStack {
                    Spacer()
                    Button {
                        viewModel.saveGridSettings()
                    } label: {
                        Label(L10n.applyButton, systemImage: "checkmark.circle.fill")
                    }
                    .keyboardShortcut(.defaultAction)
                }
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
                    HotkeyRecorderView(keyCode: $viewModel.hotkeyKeyCode, carbonModifiers: $viewModel.hotkeyCarbonModifiers)
                        .frame(width: 160, height: 24)
                }
            } header: {
                Label(L10n.tabTriggers, systemImage: "hand.tap.fill")
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
                    gestureConflictHint
                }
            } header: {
                Label(L10n.trackpadGestureGroupTitle, systemImage: "hand.point.up.braille")
            }

            Section {
                HStack {
                    Spacer()
                    Button {
                        viewModel.saveTriggerSettings()
                    } label: {
                        Label(L10n.applyButton, systemImage: "checkmark.circle.fill")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
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
    /// standing warning is more honest than a one-time toggle.
    private var gestureConflictHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.gestureConflictHint)
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
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Advanced (combines Sources + Uninstall)

    /// Sources and Uninstall keep their own distinct view structures (a
    /// plain `Form` vs. a master-detail `HStack`+`List`) rather than being
    /// merged into one shared layout — a segmented control switches
    /// between them instead of stacking two very differently-shaped views
    /// in one scroll area.
    private var advancedTab: some View {
        VStack(spacing: 0) {
            Picker("", selection: $viewModel.advancedSubTab) {
                Text(L10n.tabSources).tag(AdvancedSubTab.sources)
                Text(L10n.tabUninstall).tag(AdvancedSubTab.uninstall)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            switch viewModel.advancedSubTab {
            case .sources: sourcesTab
            case .uninstall: uninstallTab
            }
        }
    }

    // MARK: Uninstall

    private var uninstallTab: some View {
        HStack(spacing: 0) {
            List(viewModel.uninstallCandidates, selection: Binding(
                get: { viewModel.selectedUninstallRecordID },
                set: { newValue in
                    guard let newValue else { return }
                    viewModel.selectUninstallCandidate(newValue)
                }
            )) { record in
                Label(viewModel.displayName(for: record), systemImage: "app.fill")
                    .tag(record.id)
            }
            .frame(width: 220)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if viewModel.selectedUninstallRecordID == nil {
                    ContentUnavailableLikeHint(
                        systemImage: "trash.circle",
                        text: L10n.uninstallSelectPrompt
                    )
                } else if viewModel.uninstallPlan.isEmpty {
                    ContentUnavailableLikeHint(
                        systemImage: "checkmark.circle",
                        text: L10n.uninstallNoItemsFound
                    )
                } else {
                    Label(L10n.uninstallPreviewNotice, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    List(Array(viewModel.uninstallPlan.enumerated()), id: \.offset) { _, item in
                        HStack {
                            classificationBadge(item.classification)
                            Text(item.path.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if item.requiresPrivilegedHelper {
                                Label(L10n.needsHelperLabel, systemImage: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Button {
                            viewModel.saveUninstallDryRunReport()
                        } label: {
                            Label(L10n.saveDryRunReportButton, systemImage: "doc.text")
                        }
                        Spacer()
                        Button(role: .destructive) {
                            confirmAndExecuteRemoval()
                        } label: {
                            Label(L10n.moveToTrashButton, systemImage: "trash")
                        }
                        .disabled(viewModel.itemsEligibleForRemoval.isEmpty)
                    }
                    Label(L10n.uninstallSafetyNotice, systemImage: "shield.checkerboard")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A small `Label` + secondary text placeholder, matching the tone of
    /// SwiftUI's `ContentUnavailableView` (not used directly since this
    /// project's minimum, macOS 15, technically supports it, but a plain
    /// `Label` keeps this file's styling consistent with the rest of the
    /// hand-built rows above rather than mixing two different idioms).
    private struct ContentUnavailableLikeHint: View {
        let systemImage: String
        let text: String

        var body: some View {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(text)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    /// App identity + license only — deliberately no credits/contributor
    /// list. There wasn't one before this tab existed, and none is added
    /// now.
    private var aboutTab: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
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

    /// The confirmation this project's safety rules require before any
    /// irreversible-looking action: lists exactly what will move to Trash,
    /// requires an explicit destructive-styled click, and only then calls
    /// into the view model. Trash is itself recoverable, but the dialog
    /// still exists — the user should never be surprised by what happened.
    private func confirmAndExecuteRemoval() {
        let items = viewModel.itemsEligibleForRemoval
        guard !items.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = L10n.moveToTrashAlertTitle(items.count)
        alert.informativeText = items.map(\.path.path).joined(separator: "\n")
        alert.alertStyle = .critical
        alert.addButton(withTitle: L10n.moveToTrashConfirmButton)
        alert.addButton(withTitle: L10n.cancelButton)

        if alert.runModal() == .alertFirstButtonReturn {
            viewModel.executeOwnedRemoval()
        }
    }

    private func classificationBadge(_ classification: OwnershipClassification) -> some View {
        let (label, symbol, color): (String, String, Color) = switch classification {
        case .owned: (L10n.classificationOwned, "checkmark.circle.fill", .green)
        case .sharedRisk: (L10n.classificationSharedRisk, "exclamationmark.triangle.fill", .yellow)
        case .unknown: (L10n.classificationUnknown, "questionmark.circle.fill", .red)
        }
        return Label(label, systemImage: symbol)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.18))
            .clipShape(Capsule())
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
