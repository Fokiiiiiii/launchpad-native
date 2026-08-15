import Localization
import SwiftUI

/// Discoverable close affordance for borderless glass panels.
///
/// The design reference's mock uses the familiar macOS red traffic-light position. The
/// glyph appears on hover, matching the native control without introducing a
/// full title bar.
struct PanelCloseButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                    .overlay {
                        Circle()
                            .strokeBorder(.black.opacity(0.18), lineWidth: 0.5)
                    }
                Image(systemName: "xmark")
                    .font(.system(size: 6.5, weight: .black))
                    .foregroundStyle(.black.opacity(0.62))
                    .opacity(isHovering ? 1 : 0)
            }
            .frame(width: 13, height: 13)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(L10n.closePanelAccessibilityLabel)
    }
}
