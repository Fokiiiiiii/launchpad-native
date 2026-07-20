import AppKit

/// Liquid Glass surface for the launcher background. Uses the public
/// `NSGlassEffectView` (macOS 26+, confirmed present in
/// `ReverseEngineering/Contracts/public-tier1.md`) and falls back to
/// `NSVisualEffectView` below that, since this package's deployment target
/// (`.v15`) must still build on slightly older runtimes.
///
/// Per Apple's docs, `NSGlassEffectView.contentView` does not guarantee
/// subview z-order, so the content view here holds exactly one child
/// (the launcher's root content stack), never multiple ad-hoc subviews.
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
            background = glass
        } else {
            let fallback = NSVisualEffectView()
            fallback.material = reduceTransparency ? .underWindowBackground : .hudWindow
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

    /// Sets `contentView` on an `NSGlassEffectView`, or adds as a subview for
    /// the `NSVisualEffectView` fallback — the two types don't share an API
    /// for "the one child view," so this centralizes the branch.
    static func setContent(_ content: NSView, on background: NSView) {
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.contentView = content
        } else {
            background.addSubview(content)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
    }
}
