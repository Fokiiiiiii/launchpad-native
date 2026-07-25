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
            gridTab.tabItem { Label(L10n.tabGrid, systemImage: "square.grid.3x3") }.tag(SettingsTab.grid)
            triggersTab.tabItem { Label(L10n.tabTriggers, systemImage: "hand.tap") }.tag(SettingsTab.triggers)
            sourcesTab.tabItem { Label(L10n.tabSources, systemImage: "folder") }.tag(SettingsTab.sources)
            hiddenTab.tabItem { Label(L10n.tabHidden, systemImage: "eye.slash") }.tag(SettingsTab.hidden)
            uninstallTab.tabItem { Label(L10n.tabUninstall, systemImage: "trash") }.tag(SettingsTab.uninstall)
        }
        .padding()
        .frame(width: 480, height: 420)
    }

    private var gridTab: some View {
        Form {
            Stepper(L10n.columnsLabel(viewModel.columns), value: $viewModel.columns, in: 3...12)
            Stepper(L10n.rowsLabel(viewModel.rows), value: $viewModel.rows, in: 2...8)
            VStack(alignment: .leading) {
                Text(L10n.iconSizeLabel(Int(viewModel.iconSize)))
                Slider(value: $viewModel.iconSize, in: 48...160)
                    .accessibilityLabel(L10n.iconSizeAccessibilityLabel)
            }
            Picker(L10n.layoutPickerLabel, selection: $viewModel.layoutMode) {
                Text(L10n.layoutModePaged).tag(LayoutMode.paged)
                Text(L10n.layoutModeVerticalScroll).tag(LayoutMode.verticalScroll)
            }
            .pickerStyle(.segmented)
            Button(L10n.applyButton) { viewModel.saveGridSettings() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private var triggersTab: some View {
        Form {
            Toggle(L10n.f4ToggleLabel, isOn: $viewModel.f4Enabled)
            if viewModel.f4Enabled && !viewModel.f4Active {
                f4PermissionHint
            }

            Toggle(L10n.globalHotkeyToggleLabel, isOn: $viewModel.hotkeyEnabled)
            if viewModel.hotkeyEnabled {
                HotkeyRecorderView(keyCode: $viewModel.hotkeyKeyCode, carbonModifiers: $viewModel.hotkeyCarbonModifiers)
                    .frame(width: 160, height: 24)
            }

            GroupBox(L10n.hotCornersGroupTitle) {
                Toggle(L10n.hotCornerTopLeft, isOn: $viewModel.hotCornerTopLeft)
                Toggle(L10n.hotCornerTopRight, isOn: $viewModel.hotCornerTopRight)
                Toggle(L10n.hotCornerBottomLeft, isOn: $viewModel.hotCornerBottomLeft)
                Toggle(L10n.hotCornerBottomRight, isOn: $viewModel.hotCornerBottomRight)
            }

            GroupBox(L10n.trackpadGestureGroupTitle) {
                Toggle(L10n.multitouchToggleLabel, isOn: $viewModel.multitouchEnabled)
                VStack(alignment: .leading) {
                    Text(L10n.sensitivityLabel)
                    Slider(value: $viewModel.multitouchSensitivity, in: 0.3...0.8)
                        .accessibilityLabel(L10n.gestureSensitivityAccessibilityLabel)
                }
                if viewModel.multitouchEnabled {
                    gestureConflictHint
                }
            }

            Button(L10n.applyButton) { viewModel.saveTriggerSettings() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
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
        .padding(.leading, 16)
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
        .padding(.leading, 16)
    }

    private var sourcesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(viewModel.customSources, id: \.id) { source in
                    HStack {
                        Text(source.rootPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(L10n.removeButton) { viewModel.removeCustomSource(id: source.id) }
                    }
                }
            }
            Button(L10n.addFolderButton) { addFolder() }
        }
        .padding()
    }

    private var hiddenTab: some View {
        VStack(alignment: .leading) {
            if viewModel.hiddenApps.isEmpty {
                Text(L10n.noHiddenAppsMessage)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List {
                    ForEach(viewModel.hiddenApps, id: \.identifier) { entry in
                        HStack {
                            Text(entry.name)
                            Spacer()
                            Button(L10n.unhideButton) { viewModel.unhide(entry.identifier) }
                        }
                    }
                }
            }
        }
        .padding()
    }

    private var uninstallTab: some View {
        HStack(spacing: 0) {
            List(viewModel.uninstallCandidates, selection: Binding(
                get: { viewModel.selectedUninstallRecordID },
                set: { newValue in
                    guard let newValue else { return }
                    viewModel.selectUninstallCandidate(newValue)
                }
            )) { record in
                Text(viewModel.displayName(for: record)).tag(record.id)
            }
            .frame(width: 200)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if viewModel.selectedUninstallRecordID == nil {
                    Text(L10n.uninstallSelectPrompt)
                        .foregroundStyle(.secondary)
                        .padding()
                } else if viewModel.uninstallPlan.isEmpty {
                    Text(L10n.uninstallNoItemsFound)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    Text(L10n.uninstallPreviewNotice)
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
                                Text(L10n.needsHelperLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Button(L10n.saveDryRunReportButton) { viewModel.saveUninstallDryRunReport() }
                        Spacer()
                        Button(L10n.moveToTrashButton) { confirmAndExecuteRemoval() }
                            .disabled(viewModel.itemsEligibleForRemoval.isEmpty)
                    }
                    Text(L10n.uninstallSafetyNotice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
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
        let (label, color): (String, Color) = switch classification {
        case .owned: (L10n.classificationOwned, .green)
        case .sharedRisk: (L10n.classificationSharedRisk, .yellow)
        case .unknown: (L10n.classificationUnknown, .red)
        }
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.25))
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
