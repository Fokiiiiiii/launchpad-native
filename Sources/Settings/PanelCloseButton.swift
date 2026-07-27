import Localization
import SwiftUI

/// Round 13 §A: with the native titlebar close button now hidden on both
/// Settings and the Uninstall panel (matching the reference design's
/// borderless floating-card look), outside-click-dismiss and Escape are the
/// only remaining ways to close either window — neither is discoverable to
/// a first-time user. This small in-content affordance trades a little
/// visual fidelity to the reference (which shows no close button at all)
/// for the user's own explicit "more usable" instruction.
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
