import AppKit

/// `Onboarding`-module-local duplicate of `Grid.GlassBackgroundHelper.makeFolderCardBackground`
/// — `Onboarding` deliberately doesn't depend on `Grid` (that would pull in
/// Grid's SQLite linking plus its own Catalog/Persistence/WindowBrowser
/// dependency chain just for a decorative background), following the same
/// precedent already established for the identical situation:
/// `Launcher/GlassBackgroundView.swift` and `Grid/GlassBackgroundHelper.swift`
/// are themselves parallel duplicates of the same glass-card logic, because
/// `Grid` sits below `Launcher` in the dependency graph.
/// `WhatsNew/WhatsNewGlassBackground.swift` is a third copy, for the same
/// reason.
enum OnboardingGlassBackground {
    static func make(
        cornerRadius: CGFloat,
        tint: NSColor = NSColor.white.withAlphaComponent(0.07),
        borderAlpha: CGFloat = 0.13,
        shadowOpacity: Float = 0.60,
        shadowRadius: CGFloat = 55,
        shadowOffset: CGSize = CGSize(width: 0, height: -27)
    ) -> NSView {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

        let container = NSView()
        container.wantsLayer = true
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
