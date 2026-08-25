import AppKit
import DesignSystem
import Diagnostics
import Localization
import Persistence
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    // MARK: - Apps

    var appsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: Metrics.sectionHeaderSpacing) {
                    SettingsSectionHeader(L10n.tabApps, systemImage: "square.dashed.inset.filled", tint: .gray)
                SettingsCard {
                    if viewModel.hiddenApps.isEmpty {
                        VStack(spacing: 5) {
                            Text(L10n.noHiddenAppsMessage)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(L10n.noHiddenAppsHint)
                                .font(.caption)
                                .foregroundStyle(.secondary.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity, minHeight: 72)
                    } else {
                        ForEach(Array(viewModel.hiddenApps.enumerated()), id: \.element.identifier) { index, entry in
                            if index > 0 { SettingsCardDivider() }
                            SettingsCardRow(minHeight: 34) {
                                HStack {
                                    Label(entry.name, systemImage: "eye.slash.fill")
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                    Spacer()
                                    Button(L10n.unhideButton) {
                                        viewModel.unhide(entry.identifier)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                }

                SettingsCard {
                    SettingsCardRow(minHeight: 34) {
                        Toggle(isOn: $viewModel.showMenuBarApplications) {
                            Text(L10n.showMenuBarApplicationsToggleLabel)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow(minHeight: 34) {
                        Toggle(isOn: $viewModel.showsHiddenAppsInSearch) {
                            Text(L10n.showHiddenAppsInSearchToggleLabel)
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.contentHorizontalPadding)
            .padding(.top, Metrics.contentTopPadding)
            .padding(.bottom, Metrics.contentBottomPadding)
        }
    }
}
