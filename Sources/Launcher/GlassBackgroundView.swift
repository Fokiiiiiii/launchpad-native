import AppKit
import DesignSystem

/// Launcher-local facade for the shared decorative Liquid Glass surface.
///
/// Keeping this name avoids coupling launcher call sites to implementation
/// details while the actual accessibility and hit-testing behavior lives in
/// DesignSystem.
@MainActor
enum GlassBackgroundFactory {
    static func makeBackground(cornerRadius: CGFloat) -> NSView {
        GlassSurfaceFactory.makeBackground(cornerRadius: cornerRadius)
    }
}
