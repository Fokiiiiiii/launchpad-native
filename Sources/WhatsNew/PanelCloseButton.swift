import Localization
import SwiftUI

/// `WhatsNew`-module-local duplicate of `Settings.PanelCloseButton` — same
/// in-content close affordance (outside-click-dismiss and Escape aren't
/// discoverable to a first-time user). Reuses the shared `L10n` string
/// rather than defining its own — see `WhatsNewGlassBackground.swift`'s doc
/// comment for why this module keeps its own small AppKit/SwiftUI copies
/// instead of depending on `Settings` itself (only `Localization` is
/// shared, since every module already depends on it).
struct PanelCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.closePanelAccessibilityLabel)
    }
}
