import AppKit

/// Liquid Glass surface for the launcher background. Uses the public
/// `NSGlassEffectView` (macOS 26+, confirmed present in
/// `ReverseEngineering/Contracts/public-tier1.md`) and falls back to
/// `NSVisualEffectView` below that, since this package's deployment target
/// (`.v15`) must still build on slightly older runtimes.
///
/// This view is purely decorative — a background layer, never a container
/// for interactive content. Apple's own docs say `NSGlassEffectView.contentView`
/// doesn't guarantee subview z-order; hands-on testing confirmed the practical
/// consequence is worse than a visual quirk — clicks, buttons, and collection
/// view cells hosted inside `contentView` stopped receiving mouse events
/// reliably. `LauncherWindowController` now adds this view and the real
/// interactive content as *sibling* subviews of a plain `NSView` (background
/// first, content on top), which guarantees normal AppKit hit-testing.
@MainActor
enum GlassBackgroundFactory {
    /// Reduce Transparency asks for a frostier/near-solid surface rather than
    /// no feedback at all; Increase Contrast asks for a defined border. Both
    /// are read from `NSWorkspace` live (not cached), since a user can toggle
    /// them in System Settings while the launcher is closed.
    static func makeBackground(cornerRadius: CGFloat) -> NSView {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

        let background: NSView
        if #available(macOS 26.0, *), !reduceTransparency {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            // A near-opaque default tint made the launcher read as a heavy
            // black overlay rather than a light glass surface (unfavorably
            // compared, during hands-on testing, to lighter wallpaper-
            // forward reference designs). A faint neutral tint keeps the
            // material readable as "glass" without crushing the desktop
            // wallpaper behind it.
            glass.tintColor = NSColor.black.withAlphaComponent(0.08)
            background = glass
        } else {
            let fallback = NSVisualEffectView()
            // `.hudWindow` renders quite dark; `.underWindowBackground`
            // adapts to the desktop behind it and reads much lighter,
            // matching the same intent as the glass tint above. Reduce
            // Transparency still gets a frostier, more opaque material
            // (`.sidebar`) rather than sacrificing that accessibility need
            // for style.
            fallback.material = reduceTransparency ? .sidebar : .underWindowBackground
            fallback.blendingMode = .behindWindow
            fallback.state = .active
            fallback.wantsLayer = true
            fallback.layer?.cornerRadius = cornerRadius
            fallback.layer?.masksToBounds = true
            background = fallback
        }

        if increaseContrast {
            background.wantsLayer = true
            background.layer?.borderWidth = 1
            background.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.6).cgColor
        }
        return background
    }
}
