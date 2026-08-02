import SwiftUI

/// Round 20: replaces `.formStyle(.grouped)`'s native System-Settings-style
/// look with the Tessera reference's own section-card styling
/// (`SettingsWindowView.swift`'s HTML cross-check: section background
/// `rgba(255,255,255,.055)`, `1px solid rgba(255,255,255,.06)` border,
/// `10px` corner radius, `46pt` row height, inter-row divider inset
/// `13pt`) — macOS's `Form`/`Section` APIs have no public way to restyle a
/// section's own background/corner radius, so this is a plain `VStack`
/// standing in for `Section`'s *container*, while every `Toggle`/`Picker`/
/// `Stepper`/`Slider` already inside each tab is unchanged (only the
/// surrounding markup moved from `Form { Section { ... } }` to
/// `SettingsCard { SettingsCardRow { ... } }`).
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

struct SettingsCardRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 13)
            .frame(minHeight: 46, alignment: .leading)
    }
}

struct SettingsCardDivider: View {
    var body: some View {
        Divider().padding(.leading, 13)
    }
}
