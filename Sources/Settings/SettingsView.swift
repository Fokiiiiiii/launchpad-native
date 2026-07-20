import AppKit
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
            gridTab.tabItem { Label("Grid", systemImage: "square.grid.3x3") }.tag(SettingsTab.grid)
            triggersTab.tabItem { Label("Triggers", systemImage: "hand.tap") }.tag(SettingsTab.triggers)
            sourcesTab.tabItem { Label("Sources", systemImage: "folder") }.tag(SettingsTab.sources)
            hiddenTab.tabItem { Label("Hidden Apps", systemImage: "eye.slash") }.tag(SettingsTab.hidden)
            uninstallTab.tabItem { Label("Uninstall", systemImage: "trash") }.tag(SettingsTab.uninstall)
        }
        .padding()
        .frame(width: 480, height: 420)
    }

    private var gridTab: some View {
        Form {
            Stepper("Columns: \(viewModel.columns)", value: $viewModel.columns, in: 3...12)
            Stepper("Rows: \(viewModel.rows)", value: $viewModel.rows, in: 2...8)
            VStack(alignment: .leading) {
                Text("Icon size: \(Int(viewModel.iconSize))pt")
                Slider(value: $viewModel.iconSize, in: 48...160)
            }
            Picker("Layout", selection: $viewModel.layoutMode) {
                Text("Paged").tag(LayoutMode.paged)
                Text("Vertical Scroll").tag(LayoutMode.verticalScroll)
            }
            .pickerStyle(.segmented)
            Button("Apply") { viewModel.saveGridSettings() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private var triggersTab: some View {
        Form {
            Toggle("F4 / Spotlight key", isOn: $viewModel.f4Enabled)
            Toggle("Global hotkey", isOn: $viewModel.hotkeyEnabled)

            GroupBox("Hot Corners") {
                Toggle("Top Left", isOn: $viewModel.hotCornerTopLeft)
                Toggle("Top Right", isOn: $viewModel.hotCornerTopRight)
                Toggle("Bottom Left", isOn: $viewModel.hotCornerBottomLeft)
                Toggle("Bottom Right", isOn: $viewModel.hotCornerBottomRight)
            }

            GroupBox("Trackpad Gesture") {
                Toggle("4-finger pinch to open, spread to close", isOn: $viewModel.multitouchEnabled)
                VStack(alignment: .leading) {
                    Text("Sensitivity")
                    Slider(value: $viewModel.multitouchSensitivity, in: 0.3...0.8)
                }
            }

            Button("Apply") { viewModel.saveTriggerSettings() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
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
                        Button("Remove") { viewModel.removeCustomSource(id: source.id) }
                    }
                }
            }
            Button("Add Folder…") { addFolder() }
        }
        .padding()
    }

    private var hiddenTab: some View {
        VStack(alignment: .leading) {
            if viewModel.hiddenApps.isEmpty {
                Text("No hidden apps.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List {
                    ForEach(viewModel.hiddenApps, id: \.identifier) { entry in
                        HStack {
                            Text(entry.name)
                            Spacer()
                            Button("Unhide") { viewModel.unhide(entry.identifier) }
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
                    Text("Select an app to see what would be removed.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else if viewModel.uninstallPlan.isEmpty {
                    Text("No related files or registrations were found for this app.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    Text("This is a preview only — nothing is deleted or stopped yet.")
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
                                Text("needs helper")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Save Dry-Run Report") { viewModel.saveUninstallDryRunReport() }
                }
            }
            .padding()
        }
    }

    private func classificationBadge(_ classification: OwnershipClassification) -> some View {
        let (label, color): (String, Color) = switch classification {
        case .owned: ("owned", .green)
        case .sharedRisk: ("shared risk", .yellow)
        case .unknown: ("unknown", .red)
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
        panel.message = "Choose a folder to scan for applications"
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.addCustomSource(path: url.path)
        }
    }
}
