import AppKit

/// `Grid`-module-local glass/dark background factory. `Grid` cannot import
/// `Launcher.GlassBackgroundFactory` (`Grid` sits below `Launcher` in the
/// dependency graph — see `Package.swift`), so this is the one shared copy
/// for everything inside `Grid` that needs a decorative translucent
/// background: `PageControlView`'s page-pill and
/// `FolderContentsViewController`'s popover card. Previously each view had
/// its own ad-hoc ~15-line copy of the same logic; this consolidates them.
enum GlassBackgroundHelper {
    static func makeBackground(cornerRadius: CGFloat, dark: Bool = false) -> NSView {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if #available(macOS 26.0, *), !reduceTransparency {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = NSColor.black.withAlphaComponent(dark ? 0.35 : 0.08)
            return glass
        }
        let fallback = NSVisualEffectView()
        fallback.material = reduceTransparency ? .sidebar : (dark ? .hudWindow : .underWindowBackground)
        fallback.blendingMode = dark ? .withinWindow : .behindWindow
        fallback.state = .active
        fallback.wantsLayer = true
        fallback.layer?.cornerRadius = cornerRadius
        fallback.layer?.masksToBounds = true
        return fallback
    }

}
