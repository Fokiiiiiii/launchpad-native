import AppKit
import DesignSystem
import Diagnostics
import Localization
import Persistence
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    // MARK: - About

    var aboutTab: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 0) {
                Image(
                    nsImage: AppIconStyleApplier.image(for: viewModel.appIconStyle, pointSize: 76)
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

    func displayName(for style: AppIconStyle) -> String {
        switch style {
        case .classic: L10n.appIconStyleClassic
        case .monochrome: L10n.appIconStyleMonochrome
        case .solid: L10n.appIconStyleSolid
        case .diagonal: L10n.appIconStyleDiagonal
        }
    }
}
