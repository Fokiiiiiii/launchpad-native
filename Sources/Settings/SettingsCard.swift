import AppKit
import SwiftUI

/// A restrained hierarchy layer above the window's native Liquid Glass.
struct SettingsCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder var content: () -> Content

    private var fill: Color {
        if reduceTransparency {
            return Color(nsColor: .windowBackgroundColor)
        }
        return Color.white.opacity(colorScheme == .dark ? 0.055 : 0.34)
    }

    private var border: Color {
        Color.white.opacity(colorScheme == .dark ? 0.06 : 0.42)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct SettingsSectionHeader: View {
    let title: String
    let systemImage: String
    let tint: Color

    init(_ title: String, systemImage: String, tint: Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SettingsCardRow<Content: View>: View {
    @ScaledMetric(relativeTo: .body) private var scaledMinHeight: CGFloat = 40
    @ViewBuilder var content: () -> Content

    init(minHeight: CGFloat = 40, @ViewBuilder content: @escaping () -> Content) {
        _scaledMinHeight = ScaledMetric(wrappedValue: minHeight, relativeTo: .body)
        self.content = content
    }

    var body: some View {
        content()
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: scaledMinHeight, alignment: .leading)
            .toggleStyle(.switch)
    }
}

struct SettingsCardDivider: View {
    var body: some View {
        Divider()
            .opacity(0.55)
            .padding(.horizontal, 11)
    }
}
