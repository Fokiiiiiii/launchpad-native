import AppKit

/// A minimal page-dot indicator + click-to-jump, standing in for full
/// gesture-driven paging (rubber-band/velocity projection per apple-design
/// is a follow-up polish pass — see PagedGridLayout's doc comment).
final class PageControlView: NSView {
    var onSelectPage: ((Int) -> Void)?

    var numberOfPages: Int = 1 {
        didSet { rebuildDots() }
    }

    var currentPage: Int = 0 {
        didSet { updateDotStates() }
    }

    private var dotButtons: [NSButton] = []
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 8
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

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
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 6),
                button.heightAnchor.constraint(equalToConstant: 6)
            ])
            stack.addArrangedSubview(button)
            dotButtons.append(button)
        }
        updateDotStates()
    }

    private func updateDotStates() {
        for (index, button) in dotButtons.enumerated() {
            button.layer?.backgroundColor = index == currentPage
                ? NSColor.labelColor.cgColor
                : NSColor.tertiaryLabelColor.cgColor
        }
    }

    @objc private func dotClicked(_ sender: NSButton) {
        onSelectPage?(sender.tag)
    }
}
