import Localization
import SwiftUI

/// Ported from the design reference's `Dialogs.swift`
/// `WhatsNewView`/`WhatsNewRow` — same width (640), padding, spacing, and
/// typography, with real content in place of the reference's placeholder
/// rows (see `WhatsNewFeature`'s doc comment for why a plain SF Symbol
/// stands in for the reference's illustrated thumbnails).
public struct WhatsNewView: View {
    let version: String
    let features: [WhatsNewFeature]
    let onContinue: () -> Void
    let onClose: () -> Void

    public init(version: String, features: [WhatsNewFeature], onContinue: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.version = version
        self.features = features
        self.onContinue = onContinue
        self.onClose = onClose
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 26) {
                header
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                        row(for: feature)
                        if index < features.count - 1 {
                            Divider()
                        }
                    }
                }
                footer
            }
            .padding(EdgeInsets(top: 40, leading: 44, bottom: 34, trailing: 44))

            PanelCloseButton(action: onClose)
                .padding(16)
        }
        .frame(width: 640)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(L10n.whatsNewTitle)
                .font(.system(size: 26, weight: .semibold))
            Text(L10n.whatsNewVersionBadge(version))
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func row(for feature: WhatsNewFeature) -> some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .overlay(
                    Image(systemName: feature.symbolName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.system(size: 14.5, weight: .semibold))
                Text(feature.body)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white.opacity(0.66))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onContinue) {
                Text(L10n.whatsNewContinueButton)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}
