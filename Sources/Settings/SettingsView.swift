import AppKit
import DesignSystem
import Diagnostics
import Localization
import Persistence
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let onClose: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var tabIconSize: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var tabItemHeight: CGFloat = 52
    @State var showResetGridConfirmation = false
    @State var isExportingDiagnostics = false
    @State var isHandlingLayoutBackup = false

    enum Metrics {
        static let sectionSpacing: CGFloat = 13
        static let sectionHeaderSpacing: CGFloat = 5
        static let contentHorizontalPadding: CGFloat = 11
        static let contentTopPadding: CGFloat = 10
        static let contentBottomPadding: CGFloat = 12
    }

    let accent = Color.accentColor

    public init(viewModel: SettingsViewModel, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Reserve only the compact draggable band used by the reference.
            // The enclosing window is borderless, so this band starts at the
            // actual glass-card edge without an invisible native titlebar.
            Color.clear
                .frame(height: 44)

            settingsTabBar

            Rectangle()
                .fill(contrast == .increased ? Color.primary.opacity(0.45) : Color.white.opacity(0.10))
                .frame(height: 1)

            selectedTabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topLeading) {
            PanelCloseButton(accessibilityLabel: L10n.closePanelAccessibilityLabel, hitTargetSize: 32, action: onClose)
                .padding(.leading, 8)
                .padding(.top, 8)
        }
        .font(.system(size: 15))
        .controlSize(.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsTabDefinitions: [(SettingsTab, String, String)] {
        [
            (.general, L10n.tabGeneral, "gearshape"),
            (.screen, L10n.tabScreen, "circle.hexagongrid"),
            (.apps, L10n.tabApps, "square.dashed.inset.filled"),
            (.advanced, L10n.tabAdvanced, "slider.horizontal.3"),
            (.about, L10n.tabAbout, "info.circle")
        ]
    }

    private var settingsTabBar: some View {
        HStack(spacing: 2) {
            ForEach(settingsTabDefinitions.indices, id: \.self) { index in
                let tab = settingsTabDefinitions[index]
                let selected = viewModel.selectedTab == tab.0

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.selectedTab = tab.0
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.2)
                            .font(.system(size: tabIconSize, weight: .regular))
                            .frame(height: tabIconSize + 2)
                        Text(tab.1)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selected ? accent : Color.white.opacity(0.72))
                    .frame(maxWidth: .infinity, minHeight: tabItemHeight)
                    .contentShape(Rectangle())
                    .background(
                        selected ? Color.white.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(tab.1))
                .accessibilityValue(Text(selected ? L10n.selectedAccessibilityValue : ""))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch viewModel.selectedTab {
        case .general:
            generalTab
        case .screen:
            screenTab
        case .apps:
            appsTab
        case .advanced:
            advancedTab
        case .about:
            aboutTab
        }
    }

    var f4PermissionHint: some View {
        permissionHint(L10n.f4PermissionHint)
    }

    var trackpadPermissionHint: some View {
        permissionHint(L10n.trackpadPermissionHint)
    }

    func permissionHint(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
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

    func addFolder() {
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
