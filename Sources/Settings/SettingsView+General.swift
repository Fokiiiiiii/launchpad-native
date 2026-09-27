import AppKit
import DesignSystem
import Diagnostics
import Localization
import Persistence
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    // MARK: - General

    var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: Metrics.sectionHeaderSpacing) {
                    SettingsSectionHeader(L10n.tabTriggers, systemImage: "hand.tap.fill", tint: .orange)
                SettingsCard {
                    SettingsCardRow {
                        Toggle(isOn: $viewModel.launchAtLoginEnabled) {
                            Text(L10n.launchAtLoginToggleLabel)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: $viewModel.hotkeyEnabled) {
                                Text(L10n.globalHotkeyToggleLabel)
                            }
                            if viewModel.hotkeyEnabled {
                                HotkeyRecorderView(
                                    keyCode: $viewModel.hotkeyKeyCode,
                                    carbonModifiers: $viewModel.hotkeyCarbonModifiers,
                                    onCommit: { keyCode, modifiers in
                                        viewModel.recordHotkey(
                                            keyCode: keyCode,
                                            carbonModifiers: modifiers
                                        )
                                    }
                                )
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .frame(height: 24)
                            }
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: $viewModel.f4Enabled) {
                                Text(L10n.f4ToggleLabel)
                            }
                            if viewModel.f4Enabled && !viewModel.f4Active {
                                f4PermissionHint
                            }
                        }
                    }
                }
                }

                VStack(alignment: .leading, spacing: Metrics.sectionHeaderSpacing) {
                    SettingsSectionHeader(L10n.hotCornersGroupTitle, systemImage: "rectangle.inset.filled", tint: .orange)
                SettingsCard {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 0),
                            GridItem(.flexible(), spacing: 0)
                        ],
                        spacing: 0
                    ) {
                        hotCornerToggle(
                            L10n.hotCornerTopLeft,
                            systemImage: "arrow.up.left.square",
                            isOn: $viewModel.hotCornerTopLeft
                        )
                        hotCornerToggle(
                            L10n.hotCornerTopRight,
                            systemImage: "arrow.up.right.square",
                            isOn: $viewModel.hotCornerTopRight
                        )
                        hotCornerToggle(
                            L10n.hotCornerBottomLeft,
                            systemImage: "arrow.down.left.square",
                            isOn: $viewModel.hotCornerBottomLeft
                        )
                        hotCornerToggle(
                            L10n.hotCornerBottomRight,
                            systemImage: "arrow.down.right.square",
                            isOn: $viewModel.hotCornerBottomRight
                        )
                    }
                }
                }

                VStack(alignment: .leading, spacing: Metrics.sectionHeaderSpacing) {
                    SettingsSectionHeader(L10n.trackpadGestureGroupTitle, systemImage: "hand.point.up.braille", tint: .orange)
                SettingsCard {
                    SettingsCardRow(minHeight: 34) {
                        Toggle(isOn: $viewModel.multitouchEnabled) {
                            Text(L10n.multitouchToggleLabel)
                        }
                    }
                    if viewModel.multitouchEnabled {
                        SettingsCardDivider()
                        SettingsCardRow(minHeight: 34) {
                            HStack(spacing: 10) {
                                Label {
                                    Text(L10n.fingerCountLabel)
                                } icon: {
                                    Image(systemName: "hand.point.up.left.fill")
                                        .foregroundStyle(.orange)
                                }
                                Spacer(minLength: 8)
                                Picker(L10n.fingerCountLabel, selection: $viewModel.multitouchFingerCount) {
                                    Text(L10n.fingerCountFour).tag(4)
                                    Text(L10n.fingerCountFive).tag(5)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 118)
                            }
                        }
                        SettingsCardDivider()
                        SettingsCardRow(minHeight: 34) {
                            HStack(spacing: 10) {
                                Text(L10n.sensitivityLabel)
                                Slider(value: $viewModel.multitouchSensitivity, in: 0.3...0.8)
                                    .accessibilityLabel(Text(L10n.gestureSensitivityAccessibilityLabel))
                            }
                        }
                        if viewModel.multitouchActive,
                           !viewModel.multitouchEventArbitrationActive {
                            SettingsCardDivider()
                            SettingsCardRow {
                                trackpadPermissionHint
                            }
                        }
                    }
                }
                }

                VStack(alignment: .leading, spacing: Metrics.sectionHeaderSpacing) {
                    SettingsSectionHeader(L10n.appearanceSectionHeader, systemImage: "eye.fill", tint: .orange)
                SettingsCard {
                    SettingsCardRow(minHeight: 34) {
                        Toggle(isOn: $viewModel.showsMenuBarIcon) {
                            Text(L10n.showMenuBarIconToggleLabel)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        HStack(spacing: 10) {
                            ForEach(AppIconStyle.allCases, id: \.self) { style in
                                Button {
                                    viewModel.appIconStyle = style
                                } label: {
                                    Image(nsImage: AppIconStyleApplier.image(for: style, pointSize: 40) ?? NSImage())
                                        .resizable()
                                        .frame(width: 40, height: 40)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(
                                                    viewModel.appIconStyle == style ? accent : Color.clear,
                                                    lineWidth: 2
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(displayName(for: style)))
                                .accessibilityValue(
                                    Text(viewModel.appIconStyle == style ? L10n.selectedAccessibilityValue : "")
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityHint(Text(L10n.appIconLimitedEffectNotice))
                    }
                }
                }
            }
            .padding(.horizontal, Metrics.contentHorizontalPadding)
            .padding(.top, Metrics.contentTopPadding)
            .padding(.bottom, Metrics.contentBottomPadding)
        }
    }

    @ViewBuilder
    private func hotCornerToggle(
        _ label: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            Label(label, systemImage: systemImage)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .padding(.horizontal, 11)
    }
}
