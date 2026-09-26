import AppKit
import DesignSystem
import Diagnostics
import Localization
import Persistence
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    // MARK: - Screen

    var screenTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: Metrics.sectionHeaderSpacing) {
                    SettingsSectionHeader(L10n.gridLayoutSectionHeader, systemImage: "square.grid.3x3.fill", tint: .blue)
                SettingsCard {
                    SettingsCardRow(minHeight: 34) {
                        HStack {
                            Text(L10n.columnsLabel(viewModel.columns))
                            Spacer()
                            Stepper(value: $viewModel.columns, in: 3...12) {
                                Text("\(viewModel.columns)")
                            }
                            .labelsHidden()
                            .accessibilityLabel(Text(L10n.columnsLabel(viewModel.columns)))
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow(minHeight: 34) {
                        HStack {
                            Text(L10n.rowsLabel(viewModel.rows))
                            Spacer()
                            Stepper(value: $viewModel.rows, in: 2...8) {
                                Text("\(viewModel.rows)")
                            }
                            .labelsHidden()
                            .accessibilityLabel(Text(L10n.rowsLabel(viewModel.rows)))
                        }
                    }
                    SettingsCardDivider()
                    layoutSliderRow(
                        label: L10n.horizontalSpacingLabel(Int(viewModel.horizontalSpacing)),
                        value: $viewModel.horizontalSpacing,
                        range: 8...64
                    )
                    SettingsCardDivider()
                    layoutSliderRow(
                        label: L10n.verticalSpacingLabel(Int(viewModel.verticalSpacing)),
                        value: $viewModel.verticalSpacing,
                        range: 8...64
                    )
                    SettingsCardDivider()
                    layoutSliderRow(
                        label: L10n.pageMarginsLabel(Int(viewModel.pageMargins)),
                        value: $viewModel.pageMargins,
                        range: 24...96
                    )
                    SettingsCardDivider()
                    SettingsCardRow(minHeight: 34) {
                        HStack {
                            Spacer()
                            Button(role: .destructive) {
                                showResetGridConfirmation = true
                            } label: {
                                Text(L10n.resetGridLayoutButton)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                }

                VStack(alignment: .leading, spacing: Metrics.sectionHeaderSpacing) {
                    SettingsSectionHeader(L10n.iconScaleSectionHeader, systemImage: "app.gift.fill", tint: .blue)
                SettingsCard {
                    HStack(spacing: 6) {
                        ForEach(GridIconScalePreset.selectableCases, id: \.self) { preset in
                            iconScalePresetButton(preset)
                        }
                    }
                    .padding(9)
                    SettingsCardDivider()
                    SettingsCardRow(minHeight: 34) {
                        HStack(spacing: 10) {
                            Text(L10n.iconScaleManualLabel)
                            Slider(
                                value: $viewModel.iconScale,
                                in: GridIconScalePreset.supportedScaleRange,
                                step: 0.01
                            )
                            .accessibilityLabel(Text(L10n.iconScaleManualLabel))
                            Text("\(Int(viewModel.iconScale * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Text(L10n.iconScaleHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 11)
                        .padding(.bottom, 9)
                }
                }

                VStack(alignment: .leading, spacing: Metrics.sectionHeaderSpacing) {
                    SettingsSectionHeader(L10n.displaySectionHeader, systemImage: "macwindow.badge.plus", tint: .blue)
                SettingsCard {
                    SettingsCardRow(minHeight: 34) {
                        Picker(selection: $viewModel.sortMode) {
                            Text(L10n.sortModeCustom).tag(SortMode.custom)
                            Text(L10n.sortModeName).tag(SortMode.name)
                            Text(L10n.sortModeDateAdded).tag(SortMode.dateAdded)
                            Text(L10n.sortModeLastUsed).tag(SortMode.lastUsed)
                        } label: {
                            Text(L10n.sortByLabel)
                        }
                        .pickerStyle(.menu)
                    }
                    SettingsCardDivider()
                    SettingsCardRow(minHeight: 34) {
                        HStack {
                            Text(L10n.reorganizeButton)
                            Spacer()
                            Button(L10n.reorganizeButton) {
                                viewModel.reorganizePages()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow(minHeight: 34) {
                        Toggle(isOn: $viewModel.hideDockWhileLauncherOpen) {
                            Text(L10n.hideDockToggleLabel)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow(minHeight: 34) {
                        Picker(selection: $viewModel.menuIconVisibility) {
                            Text(L10n.menuIconVisibilityAutomatic).tag(MenuIconVisibility.automatic)
                            Text(L10n.menuIconVisibilityVisible).tag(MenuIconVisibility.visible)
                            Text(L10n.menuIconVisibilityHidden).tag(MenuIconVisibility.hidden)
                        } label: {
                            Text(L10n.menuIconVisibilityLabel)
                        }
                        .pickerStyle(.menu)
                    }
                    Text(L10n.menuIconVisibilityHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 11)
                        .padding(.bottom, 9)
                }
                }

                VStack(alignment: .leading, spacing: Metrics.sectionHeaderSpacing) {
                    SettingsSectionHeader(L10n.backgroundSectionHeader, systemImage: "photo.fill", tint: .blue)
                SettingsCard {
                    HStack(spacing: 10) {
                        backgroundModeButton(.wallpaper, title: L10n.backgroundModeWallpaper)
                        backgroundModeButton(.glass, title: L10n.backgroundModeGlass)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                    if viewModel.backgroundMode == .glass {
                        SettingsCardDivider()
                        SettingsCardRow(minHeight: 34) {
                            HStack(spacing: 10) {
                                Text(L10n.glassMaterialLabel)
                                Slider(
                                    value: $viewModel.glassMaterialIntensity,
                                    in: 0...1,
                                    step: 0.05,
                                    onEditingChanged: viewModel.setGlassMaterialEditing
                                )
                                    .accessibilityLabel(Text(L10n.glassMaterialLabel))
                                Text("\(Int(viewModel.glassMaterialIntensity * 100))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    } else {
                        SettingsCardDivider()
                        SettingsCardRow(minHeight: 34) {
                            Toggle(isOn: $viewModel.blursWallpaper) {
                                Text(L10n.blurWallpaperToggleLabel)
                            }
                        }
                    }
                }
                }
            }
            .padding(.horizontal, Metrics.contentHorizontalPadding)
            .padding(.top, Metrics.contentTopPadding)
            .padding(.bottom, Metrics.contentBottomPadding)
        }
        .confirmationDialog(
            L10n.resetGridLayoutTitle,
            isPresented: $showResetGridConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.resetGridLayoutButton, role: .destructive) {
                viewModel.resetGridLayout()
            }
            Button(L10n.cancelButton, role: .cancel) {}
        } message: {
            Text(L10n.resetGridLayoutMessage)
        }
    }

    private func iconScalePresetButton(_ preset: GridIconScalePreset) -> some View {
        let selected = viewModel.iconScalePreset == preset
        return Button {
            viewModel.applyIconScalePreset(preset)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: iconScaleSystemImage(for: preset))
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 26)
                    .foregroundStyle(.white.opacity(0.82))
                    .background(
                        LinearGradient(
                            colors: [Color(red: 63 / 255, green: 95 / 255, blue: 158 / 255), Color(red: 106 / 255, green: 74 / 255, blue: 146 / 255)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                Text(iconScalePresetName(preset))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                selected ? accent.opacity(0.20) : Color.white.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        selected ? accent : Color.white.opacity(0.08),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(iconScalePresetName(preset)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func layoutSliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        SettingsCardRow(minHeight: 34) {
            HStack(spacing: 10) {
                Text(label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Slider(value: value, in: range, step: 1)
                    .accessibilityLabel(Text(label))
            }
        }
    }

    private func iconScalePresetName(_ preset: GridIconScalePreset) -> String {
        switch preset {
        case .smart: L10n.iconScalePresetSmart
        case .large: L10n.iconScalePresetLarge
        case .standard: L10n.iconScalePresetStandard
        case .compact: L10n.iconScalePresetCompact
        case .custom: L10n.iconScalePresetCustom
        }
    }

    private func iconScaleSystemImage(for preset: GridIconScalePreset) -> String {
        switch preset {
        case .smart: "sparkles"
        case .large: "arrow.up.left.and.arrow.down.right"
        case .standard: "square"
        case .compact: "square.inset.filled"
        case .custom: "slider.horizontal.3"
        }
    }

    private func backgroundModeButton(
        _ mode: LauncherBackgroundMode,
        title: String
    ) -> some View {
        let selected = viewModel.backgroundMode == mode
        return Button {
            viewModel.backgroundMode = mode
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            mode == .wallpaper
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 63 / 255, green: 95 / 255, blue: 158 / 255),
                                            Color(red: 106 / 255, green: 74 / 255, blue: 146 / 255)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                : AnyShapeStyle(Color.white.opacity(0.10))
                        )
                    if mode == .wallpaper {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                    } else {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.18))
                            .padding(10)
                            .overlay {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.78))
                            }
                    }
                }
                .frame(width: 92, height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? accent : Color.white.opacity(0.10), lineWidth: selected ? 2 : 1)
                )
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
