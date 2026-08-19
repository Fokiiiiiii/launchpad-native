import Localization
import SwiftUI

/// `WhatsNew`-module-local duplicate of `Settings.PanelCloseButton` — same
/// in-content close affordance (outside-click-dismiss and Escape aren't
/// discoverable to a first-time user). Reuses the shared `L10n` string
/// rather than defining its own; the panel surface is provided directly by
/// the shared DesignSystem target.
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
