import AppKit
import DesignSystem

@MainActor
enum WhatsNewGlassBackground {
    static func make(
        cornerRadius: CGFloat,
        tint: NSColor = NSColor.white.withAlphaComponent(0.07),
        borderAlpha: CGFloat = 0.13,
        shadowOpacity: Float = 0.60,
        shadowRadius: CGFloat = 55,
        shadowOffset: CGSize = CGSize(width: 0, height: -27)
    ) -> NSView {
        GlassSurfaceFactory.makeCardBackground(
            cornerRadius: cornerRadius,
            tint: tint,
            borderAlpha: borderAlpha,
            shadowOpacity: shadowOpacity,
            shadowRadius: shadowRadius,
            shadowOffset: shadowOffset
        )
    }
}
