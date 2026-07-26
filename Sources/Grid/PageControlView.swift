import AppKit
import Localization

/// Page-dot indicator plus explicit prev/next chevron buttons. The dots
/// alone (6x6pt, 8pt apart) turned out to be too small a hit target for
/// reliable clicking during hands-on testing ("can't get to the side
/// pages") — the chevrons give a large, unambiguous, discoverable control
/// that doesn't depend on trackpad gesture support or precise dot aim.
/// Full gesture-driven paging physics (rubber-band/velocity projection per
/// apple-design) remains a follow-up polish pass — see PagedGridLayout's
/// doc comment.
final class PageControlView: NSView {
    var onSelectPage: ((Int) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    var numberOfPages: Int = 1 {
        didSet {
            rebuildDots()
            updateChevronEnabledState()
        }
    }

    var currentPage: Int = 0 {
        didSet {
            updateDotStates()
            updateChevronEnabledState()
        }
    }

    private var dotButtons: [NSButton] = []
    private let dotStack = NSStackView()
    private let previousButton = NSButton()
    private let nextButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        dotStack.translatesAutoresizingMaskIntoConstraints = false
        dotStack.orientation = .horizontal
        dotStack.spacing = 8

        configureChevron(previousButton, symbol: "chevron.left", label: L10n.previousPageAccessibilityLabel, action: #selector(previousTapped))
        configureChevron(nextButton, symbol: "chevron.right", label: L10n.nextPageAccessibilityLabel, action: #selector(nextTapped))

        // A small glass pill behind the chevrons/dots (Photos' floating page
        // control is the reference) — a decorative sibling, added first so it
        // sits behind the buttons, never their container (same hit-testing
        // reasoning as `Launcher.GlassBackgroundFactory`, which this can't
        // import directly).
        let glassPill = GlassBackgroundHelper.makeBackground(cornerRadius: 18)
        glassPill.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glassPill)
        addSubview(previousButton)
        addSubview(dotStack)
        addSubview(nextButton)

        NSLayoutConstraint.activate([
            glassPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -8),
            glassPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 8),
            glassPill.topAnchor.constraint(equalTo: topAnchor, constant: -4),
            glassPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 4),

            previousButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            previousButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 32),
            previousButton.heightAnchor.constraint(equalToConstant: 32),

            dotStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            dotStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            nextButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 32),
            nextButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    private func configureChevron(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .circular
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
    }

    private func rebuildDots() {
        dotButtons.forEach { $0.removeFromSuperview() }
        dotButtons.removeAll()
        for index in 0..<max(numberOfPages, 1) {
            let button = NSButton(title: "", target: self, action: #selector(dotClicked(_:)))
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 3
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setAccessibilityLabel(L10n.pageNumberAccessibilityLabel(index + 1))
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 6),
                button.heightAnchor.constraint(equalToConstant: 6)
            ])
            dotStack.addArrangedSubview(button)
            dotButtons.append(button)
        }
        updateDotStates()
    }

    /// Best-effort defensive fix for an intermittent, not-reliably-reproduced
    /// symptom seen once on cold launch where the page dots rendered
    /// invisible until the next page change. `labelColor`/`tertiaryLabelColor`
    /// are dynamic, appearance-dependent colors; taking `.cgColor` resolves
    /// against whatever appearance is "current" at that instant, which could
    /// be wrong if this runs before the view is actually attached to a
    /// window with a settled effective appearance. Resolving explicitly
    /// against `effectiveAppearance` here, plus re-running on
    /// `viewDidMoveToWindow`/`viewDidChangeEffectiveAppearance` below, is a
    /// plausible mitigation — it is not confirmed to be the actual root
    /// cause of the original symptom.
    private func updateDotStates() {
        // `NSColor` has no `resolvedColor(with:)` API — the correct way to
        // force a dynamic color's `.cgColor` snapshot to resolve against a
        // specific appearance is running the read inside
        // `NSAppearance.performAsCurrentDrawingAppearance`, which sets
        // `NSAppearance.currentDrawingAppearance` for the duration of the
        // closure.
        effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
            guard let self else { return }
            for (index, button) in dotButtons.enumerated() {
                button.layer?.backgroundColor = (index == currentPage)
                    ? NSColor.labelColor.cgColor
                    : NSColor.tertiaryLabelColor.cgColor
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDotStates()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDotStates()
    }

    /// Kept simple on purpose: earlier this dimmed disabled buttons to 0.3
    /// alpha, which against this app's dark glass background read as the
    /// button having vanished entirely during hands-on testing ("after
    /// moving, the button disappears" — really just the *next* button
    /// dimming out on the last page). Both buttons now stay fully visible
    /// always; clicking past either end is already a no-op via `jumpToPage`'s
    /// own bounds check, so hiding/disabling isn't load-bearing.
    private func updateChevronEnabledState() {
        previousButton.isHidden = numberOfPages <= 1
        nextButton.isHidden = numberOfPages <= 1
    }

    @objc private func dotClicked(_ sender: NSButton) {
        onSelectPage?(sender.tag)
    }

    @objc private func previousTapped() {
        onPrevious?()
    }

    @objc private func nextTapped() {
        onNext?()
    }
}
