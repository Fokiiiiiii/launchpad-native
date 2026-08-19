import AppKit
import DesignSystem

/// Grid-local facade over the shared Liquid Glass design system.
@MainActor
public enum GlassBackgroundHelper {
    public static func makeFolderCardBackground(
        cornerRadius: CGFloat,
        tint: NSColor = NSColor.white.withAlphaComponent(0.07),
        borderAlpha: CGFloat = 0.12,
        shadowOpacity: Float = 0.5,
        shadowRadius: CGFloat = 40,
        shadowOffset: CGSize = CGSize(width: 0, height: -20)
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
