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
            if visibleDotRange != shownDotRange {
                rebuildDots()
            } else {
                updateDotStates()
            }
            updateChevronEnabledState()
        }
    }

    private static let dotSize: CGFloat = 24
    private static let dotSpacing: CGFloat = 8
    private static let chevronWidth: CGFloat = 32
    /// Clear space kept between a chevron and the nearest dot.
    private static let chevronGap: CGFloat = 8

    /// How many dots fit between the two chevrons at the current width. Not
    /// limited until the view has a width: every dot used to be drawn whatever the
    /// space, and past a handful of pages they ran under the chevrons.
    private var dotCapacity = Int.max
    private var shownDotRange: Range<Int> = 0..<0

    /// The pages whose dots are showing: all of them when they fit, otherwise a
    /// window that follows the current page. The chevrons reach every page.
    private var visibleDotRange: Range<Int> {
        let pages = max(numberOfPages, 1)
        let count = min(pages, dotCapacity)
        let start = min(max(currentPage - count / 2, 0), pages - count)
        return start..<(start + count)
    }

    private func capacity(forWidth width: CGFloat) -> Int {
        guard width > 0 else { return .max }
        let room = width - 2 * (Self.chevronWidth + Self.chevronGap)
        return max(Int((room + Self.dotSpacing) / (Self.dotSize + Self.dotSpacing)), 1)
    }

    public override func layout() {
        super.layout()
        let capacity = capacity(forWidth: bounds.width)
        guard capacity != dotCapacity else { return }
        dotCapacity = capacity
        rebuildDots()
    }

    private var dotButtons: [NSButton] = []
    /// Test-only dot count.
    var dotButtonCountForTesting: Int { dotButtons.count }
    /// Test-only: the page each showing dot stands for.
    var dotTagsForTesting: [Int] { dotButtons.map(\.tag) }
    /// Every button a click can land on, in visual order.
    var buttonsForTesting: [NSButton] { [previousButton] + dotButtons + [nextButton] }
    private let dotStack = NSStackView()
    private let previousButton = NSButton()
    private let nextButton = NSButton()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        dotStack.translatesAutoresizingMaskIntoConstraints = false
        dotStack.orientation = .horizontal
        dotStack.spacing = Self.dotSpacing

        configureChevron(previousButton, symbol: "chevron.left", label: L10n.previousPageAccessibilityLabel, action: #selector(previousTapped))
        configureChevron(nextButton, symbol: "chevron.right", label: L10n.nextPageAccessibilityLabel, action: #selector(nextTapped))

        // A small glass pill behind the chevrons/dots (Photos' floating page
        // control is the reference), reaching a little past the buttons. On
        // macOS 27 it contains them so it can respond as they are used; before
        // that it is a decorative sibling behind them, as the search pill is.
        let controls = GlassSurfaceFactory.installControlSurface(
            in: self,
            cornerRadius: 18,
            outset: NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        )
        controls.addSubview(previousButton)
        controls.addSubview(dotStack)
        controls.addSubview(nextButton)

        NSLayoutConstraint.activate([
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
        shownDotRange = visibleDotRange
        for index in shownDotRange {
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
                button.widthAnchor.constraint(equalToConstant: Self.dotSize),
                button.heightAnchor.constraint(equalToConstant: Self.dotSize)
            ])
            dotStack.addArrangedSubview(button)
            dotButtons.append(button)
        }
        updateDotStates()
    }

    private func updateDotStates() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
            guard let self else { return }
            for button in dotButtons {
                let isCurrentPage = button.tag == currentPage
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
