import AppKit
import DesignSystem
import Localization

/// Page dots with explicit previous/next controls.
public final class PageControlView: NSView {
    public var onSelectPage: ((Int) -> Void)?
    public var onPrevious: (() -> Void)?
    public var onNext: (() -> Void)?

    public var numberOfPages: Int = 1 {
        didSet {
            guard numberOfPages != oldValue else { return }
            rebuildDots()
            updateChevronEnabledState()
        }
    }

    public var currentPage: Int = 0 {
        didSet {
            guard currentPage != oldValue else { return }
            updateDotStates()
            updateChevronEnabledState()
        }
    }

    private var dotButtons: [NSButton] = []
    /// Test-only dot count.
    var dotButtonCountForTesting: Int { dotButtons.count }
    private let dotStack = NSStackView()
    private let previousButton = NSButton()
    private let nextButton = NSButton()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        dotStack.translatesAutoresizingMaskIntoConstraints = false
        dotStack.orientation = .horizontal
        dotStack.spacing = 8

        configureChevron(previousButton, symbol: "chevron.left", label: L10n.previousPageAccessibilityLabel, action: #selector(previousTapped))
        configureChevron(nextButton, symbol: "chevron.right", label: L10n.nextPageAccessibilityLabel, action: #selector(nextTapped))

        // A small glass pill behind the chevrons/dots (Photos' floating page
        // control is the reference) — a decorative sibling, added first so it
        // sits behind the buttons, never their container (same hit-testing
        // same non-interactive-surface rule as the launcher's search pill).
        let glassPill = GlassSurfaceFactory.makeBackground(cornerRadius: 18)
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

        rebuildDots()
        updateChevronEnabledState()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("unavailable") }

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
            button.focusRingType = .none
            button.image = NSImage(
                systemSymbolName: "circle.fill",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(pointSize: 6, weight: .regular))
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setAccessibilityLabel(L10n.pageNumberAccessibilityLabel(index + 1))
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 24)
            ])
            dotStack.addArrangedSubview(button)
            dotButtons.append(button)
        }
        updateDotStates()
    }

    private func updateDotStates() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
            guard let self else { return }
            for (index, button) in dotButtons.enumerated() {
                let isCurrentPage = index == currentPage
                button.contentTintColor = isCurrentPage
                    ? NSColor.labelColor
                    : NSColor.tertiaryLabelColor
                if button.isAccessibilitySelected() != isCurrentPage {
                    button.setAccessibilitySelected(isCurrentPage)
                    button.setAccessibilityValue(isCurrentPage ? L10n.selectedAccessibilityValue : nil)
                }
            }
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDotStates()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDotStates()
    }

    private func updateChevronEnabledState() {
        let hasMultiplePages = numberOfPages > 1
        previousButton.isHidden = !hasMultiplePages
        nextButton.isHidden = !hasMultiplePages

        previousButton.isEnabled = hasMultiplePages && currentPage > 0
        nextButton.isEnabled = hasMultiplePages && currentPage < numberOfPages - 1
        previousButton.contentTintColor = previousButton.isEnabled ? .labelColor : .secondaryLabelColor
        nextButton.contentTintColor = nextButton.isEnabled ? .labelColor : .secondaryLabelColor
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
