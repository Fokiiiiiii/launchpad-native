import AppKit
import Localization
import Persistence
import SwiftUI

public struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let onClose: () -> Void

    @ScaledMetric(relativeTo: .body) private var tabIconSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var tabItemHeight: CGFloat = 34

    private enum Metrics {
        static let sectionSpacing: CGFloat = 13
        static let sectionHeaderSpacing: CGFloat = 5
        static let contentHorizontalPadding: CGFloat = 11
        static let contentTopPadding: CGFloat = 10
        static let contentBottomPadding: CGFloat = 12
    }

    private let accent = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)

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
                .frame(height: 24)

            settingsTabBar

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)

            selectedTabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topLeading) {
            PanelCloseButton(action: onClose)
                .padding(.leading, 8)
                .padding(.top, 8)
        }
        .frame(width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height)
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

    // MARK: - General

    private var generalTab: some View {
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
                                    Image(nsImage: AppIconStyleApplier.previewImage(for: style) ?? NSImage())
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

    // MARK: - Screen

    private var screenTab: some View {
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
                                Slider(value: $viewModel.glassMaterialIntensity, in: 0...1, step: 0.05)
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

    private func iconScalePresetName(_ preset: GridIconScalePreset) -> String {
        switch preset {
        case .smart: L10n.iconScalePresetSmart
        case .large: L10n.iconScalePresetLarge
        case .standard: L10n.iconScalePresetStandard
        case .compact: L10n.iconScalePresetCompact
        case .custom: L10n.gridPresetCustom
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

    // MARK: - Apps

    private var appsTab: some View {
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

    // MARK: - Advanced

    private var advancedTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: Metrics.sectionHeaderSpacing) {
                    SettingsSectionHeader(L10n.tabAdvanced, systemImage: "slider.horizontal.3", tint: .gray)
                SettingsCard {
                    if viewModel.customSources.isEmpty {
                        SettingsCardRow(minHeight: 40) {
                            Text(L10n.chooseFolderPanelMessage)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        ForEach(Array(viewModel.customSources.enumerated()), id: \.element.id) { index, source in
                            if index > 0 { SettingsCardDivider() }
                            SettingsCardRow(minHeight: 34) {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.secondary)
                                    Text(source.rootPath)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Button(role: .destructive) {
                                        viewModel.removeCustomSource(id: source.id)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(Text("\(L10n.removeButton): \(source.rootPath)"))
                                }
                            }
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow(minHeight: 34) {
                        HStack {
                            Spacer()
                            Button {
                                addFolder()
                            } label: {
                                Label(L10n.addFolderButton, systemImage: "plus.circle.fill")
                            }
                            .controlSize(.small)
                        }
                    }
                }
                }
            }
            .padding(.horizontal, Metrics.contentHorizontalPadding)
            .padding(.top, Metrics.contentTopPadding)
            .padding(.bottom, Metrics.contentBottomPadding)
        }
    }

    // MARK: - About

    private var aboutTab: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 0) {
                Image(
                    nsImage: AppIconStyleApplier.previewImage(for: viewModel.appIconStyle)
                        ?? NSImage(named: NSImage.applicationIconName)
                        ?? NSImage()
                )
                .resizable()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))

                Text(Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "LaunchpadNative")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 12)

                Text(
                    L10n.aboutVersionLabel(
                        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—",
                        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

                VStack(spacing: 5) {
                    Label(L10n.aboutLicenseLabel, systemImage: "doc.text")
                    Label(L10n.aboutOpenSourceLabel, systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 14)

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.top, 16)

                Text(L10n.aboutDesignCredit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.contentHorizontalPadding)
            .padding(.top, Metrics.contentTopPadding)
            .padding(.bottom, Metrics.contentBottomPadding)
        }
    }

    // MARK: - Supporting views

    private func displayName(for style: AppIconStyle) -> String {
        switch style {
        case .classic: L10n.appIconStyleClassic
        case .monochrome: L10n.appIconStyleMonochrome
        case .solid: L10n.appIconStyleSolid
        case .diagonal: L10n.appIconStyleDiagonal
        }
    }

    private var f4PermissionHint: some View {
        permissionHint(L10n.f4PermissionHint)
    }

    private var trackpadPermissionHint: some View {
        permissionHint(L10n.trackpadPermissionHint)
    }

    private func permissionHint(_ message: String) -> some View {
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
