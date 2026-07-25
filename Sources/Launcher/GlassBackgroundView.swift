import AppKit

/// `NSGlassEffectView` used as a plain sibling (see `GlassBackgroundFactory`'s
/// doc comment) still didn't guarantee it stays out of hit-testing's way in
/// practice — a real, confirmed regression: a user's click landed squarely
/// within the search field's own logged frame (`viewDidAppear`'s diagnostic:
/// searchField at (683.5, 980, 342.5, 24), click reported at (730, 985)) yet
/// was intercepted by the *background* click catcher instead of the field,
/// closing the launcher. Apple's docs already warn `NSGlassEffectView`
/// doesn't reliably respect z-order for its `contentView`; this suggests the
/// same unreliability extends to a bare sibling instance's own hit-testing.
/// Overriding `hitTest` to unconditionally return `nil` is the direct fix:
/// a purely decorative background must never be a hit-test target at all,
/// so every click always falls through to whatever real control is drawn
/// around or in front of it, regardless of any internal z-order quirk.
@available(macOS 26.0, *)
private final class NonInteractiveGlassEffectView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class NonInteractiveVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

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
/// reliably. `LauncherWindowController` adds this view and the real
/// interactive content as *sibling* subviews of a plain `NSView` (background
/// first, content on top) — and, since that alone still wasn't reliable
/// enough (see `NonInteractiveGlassEffectView`'s doc comment), both concrete
/// types here also hard-disable their own hit-testing.
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
            let glass = NonInteractiveGlassEffectView()
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
            let fallback = NonInteractiveVisualEffectView()
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
