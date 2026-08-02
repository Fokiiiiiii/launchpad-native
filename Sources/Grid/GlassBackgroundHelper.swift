import AppKit

/// `Grid`-module-local glass/dark background factory. `Grid` cannot import
/// `Launcher.GlassBackgroundFactory` (`Grid` sits below `Launcher` in the
/// dependency graph — see `Package.swift`), so this is the one shared copy
/// for everything inside `Grid` that needs a decorative translucent
/// background: `PageControlView`'s page-pill and
/// `FolderContentsViewController`'s popover card. Previously each view had
/// its own ad-hoc ~15-line copy of the same logic; this consolidates them.
public enum GlassBackgroundHelper {
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

    /// The opened-folder card's own background — deliberately distinct from
    /// `makeBackground(dark:)` above. The Tessera reference's `.dc.html`
    /// mockup (`background:var(--foldbg,rgba(255,255,255,.07))`,
    /// `border:1px solid rgba(255,255,255,.12)`,
    /// `box-shadow:0 30px 80px rgba(0,0,0,.5), inset 0 1px 0 rgba(255,255,255,.14)`,
    /// `backdrop-filter:blur(50px) saturate(1.7)`) shows a *light*,
    /// barely-tinted white frosted glass card with a hairline border and a
    /// soft downward drop shadow — not a dark/black-tinted card, which read
    /// as a heavy black panel instead of the reference's airy floating
    /// glass. Real, confirmed report ("フォルダの背景を再度表示させて"):
    /// this was deleted in an earlier pass under the mistaken belief it was
    /// the "black background" a prior report meant — that report actually
    /// meant the per-icon shadow bug fixed in `FolderOverlayTileView.swift`
    /// (see its own doc comment). Restored verbatim from the commit that
    /// introduced it (`d5d95a0`) since this panel-level card is an
    /// independent layer from the per-icon fix and needs no changes itself.
    public static func makeFolderCardBackground(
        cornerRadius: CGFloat,
        tint: NSColor = NSColor.white.withAlphaComponent(0.07),
        borderAlpha: CGFloat = 0.12,
        shadowOpacity: Float = 0.5,
        shadowRadius: CGFloat = 40,
        shadowOffset: CGSize = CGSize(width: 0, height: -20)
    ) -> NSView {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

        let container = NSView()
        container.wantsLayer = true
        // `masksToBounds = false` on the outer container is required for the
        // drop shadow to render outside the card's own rounded rect — the
        // clipped glass/tint/border all live one level deeper, in `clip`.
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = shadowOpacity
        container.layer?.shadowRadius = shadowRadius
        container.layer?.shadowOffset = shadowOffset

        let clip = NSView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.wantsLayer = true
        clip.layer?.cornerRadius = cornerRadius
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 1
        clip.layer?.borderColor = NSColor.white.withAlphaComponent(borderAlpha).cgColor

        if #available(macOS 26.0, *), !reduceTransparency {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            glass.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(glass)
            NSLayoutConstraint.activate([
                glass.topAnchor.constraint(equalTo: clip.topAnchor),
                glass.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                glass.bottomAnchor.constraint(equalTo: clip.bottomAnchor)
            ])
        } else {
            let fallback = NSVisualEffectView()
            // `.hudWindow` is the material actually designed for floating,
            // blurred overlay chrome (matching the reference's own
            // "backdrop-filter: blur(50px)" intent) — but it renders quite
            // dark on its own, so a separate light tint overlay (below)
            // pushes it toward the reference's airy white-glass look.
            fallback.material = reduceTransparency ? .sidebar : .hudWindow
            fallback.blendingMode = .withinWindow
            fallback.state = .active
            fallback.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(fallback)
            NSLayoutConstraint.activate([
                fallback.topAnchor.constraint(equalTo: clip.topAnchor),
                fallback.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                fallback.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                fallback.bottomAnchor.constraint(equalTo: clip.bottomAnchor)
            ])
            let tintOverlay = NSView()
            tintOverlay.wantsLayer = true
            tintOverlay.layer?.backgroundColor = tint.cgColor
            tintOverlay.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(tintOverlay)
            NSLayoutConstraint.activate([
                tintOverlay.topAnchor.constraint(equalTo: clip.topAnchor),
                tintOverlay.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                tintOverlay.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                tintOverlay.bottomAnchor.constraint(equalTo: clip.bottomAnchor)
            ])
        }

        container.addSubview(clip)
        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: container.topAnchor),
            clip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }
}
