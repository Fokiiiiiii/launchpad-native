import AppKit

/// Shared macOS glass surfaces used across feature modules.
///
/// These views are decorative siblings, never content containers. Disabling
/// hit testing avoids NSGlassEffectView's internal ordering from intercepting
/// controls rendered above the surface.
@MainActor
public enum GlassSurfaceFactory {
    public static func makeBackground(
        cornerRadius: CGFloat,
        dark: Bool = false,
        tint: NSColor? = nil
    ) -> NSView {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let background: NSView

        if #available(macOS 26.0, *), !reduceTransparency {
            let glass = NonInteractiveGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint ?? NSColor.black.withAlphaComponent(dark ? 0.35 : 0.08)
            background = glass
        } else {
            let fallback = NonInteractiveVisualEffectView()
            fallback.material = reduceTransparency ? .sidebar : (dark ? .hudWindow : .underWindowBackground)
            fallback.blendingMode = dark ? .withinWindow : .behindWindow
            fallback.state = .active
            background = fallback
        }

        configureShape(background, cornerRadius: cornerRadius)
        return background
    }

    /// Puts a glass surface behind a group of controls and returns the view
    /// the controls belong in.
    ///
    /// On macOS 27 the glass is interactive: it responds visibly while the
    /// controls on it are used. That only works when the glass *contains* the
    /// controls, so there the returned view is the glass's `contentView` — the
    /// one place `NSGlassEffectView` guarantees a consistent order. Earlier
    /// systems keep the decorative, non-interactive glass as the bottom
    /// sibling behind the controls, exactly as before, and the returned view
    /// is `container` itself.
    ///
    /// `outset` lets the glass reach past the container on each side, for a
    /// pill drawn a little larger than the controls it frames.
    @discardableResult
    public static func installControlSurface(
        in container: NSView,
        cornerRadius: CGFloat,
        outset: NSEdgeInsets = NSEdgeInsets(),
        dark: Bool = false,
        tint: NSColor? = nil
    ) -> NSView {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if #available(macOS 27, *), !reduceTransparency {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint ?? NSColor.black.withAlphaComponent(dark ? 0.35 : 0.08)
            glass.effectIsInteractive = true
            // Same layer shape as every other surface here. Without it,
            // rendering the grid offscreen — as its tests do — stopped drawing
            // any icon once this glass was in the hierarchy (seen on macOS 27).
            configureShape(glass, cornerRadius: cornerRadius)
            glass.translatesAutoresizingMaskIntoConstraints = false
            let host = NSView()
            host.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = host
            container.addSubview(glass, positioned: .below, relativeTo: nil)
            pin(glass, to: container, outset: outset)
            pin(host, to: glass)
            return host
        }

        let background = makeBackground(cornerRadius: cornerRadius, dark: dark, tint: tint)
        background.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(background, positioned: .below, relativeTo: nil)
        pin(background, to: container, outset: outset)
        return container
    }

    public static func makeCardBackground(
        cornerRadius: CGFloat,
        tint: NSColor = NSColor.white.withAlphaComponent(0.07),
        borderAlpha: CGFloat = 0.12,
        shadowOpacity: Float = 0.5,
        shadowRadius: CGFloat = 40,
        shadowOffset: CGSize = CGSize(width: 0, height: -20)
    ) -> NSView {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

        let container = NonInteractiveContainerView()
        container.wantsLayer = true
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = shadowOpacity
        container.layer?.shadowRadius = shadowRadius
        container.layer?.shadowOffset = shadowOffset

        let clip = NonInteractiveContainerView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.wantsLayer = true
        clip.layer?.cornerRadius = cornerRadius
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = increaseContrast ? 1.5 : 1
        clip.layer?.borderColor = (
            increaseContrast
                ? NSColor.labelColor.withAlphaComponent(0.72)
                : NSColor.white.withAlphaComponent(borderAlpha)
        ).cgColor

        let material: NSView
        let needsTintOverlay: Bool
        if #available(macOS 26.0, *), !reduceTransparency {
            let glass = NonInteractiveGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            material = glass
            needsTintOverlay = false
        } else {
            let fallback = NonInteractiveVisualEffectView()
            fallback.material = reduceTransparency ? .sidebar : .hudWindow
            fallback.blendingMode = .withinWindow
            fallback.state = .active
            material = fallback
            needsTintOverlay = true
        }

        material.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(material)
        pin(material, to: clip)

        if needsTintOverlay {
            let tintOverlay = NonInteractiveContainerView()
            tintOverlay.wantsLayer = true
            tintOverlay.layer?.backgroundColor = tint.cgColor
            tintOverlay.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(tintOverlay)
            pin(tintOverlay, to: clip)
        }

        container.addSubview(clip)
        pin(clip, to: container)
        return container
    }

    private static func configureShape(_ view: NSView, cornerRadius: CGFloat) {
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true

        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            view.layer?.borderWidth = 1.5
            view.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.72).cgColor
        }
    }

    private static func pin(_ child: NSView, to parent: NSView, outset: NSEdgeInsets = NSEdgeInsets()) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: -outset.top),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: -outset.left),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: outset.right),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: outset.bottom)
        ])
    }
}

@available(macOS 26.0, *)
private final class NonInteractiveGlassEffectView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class NonInteractiveVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class NonInteractiveContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
