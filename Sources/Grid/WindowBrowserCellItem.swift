import AppKit

/// One window thumbnail cell: preview image, title, close/minimize buttons.
final class WindowBrowserCellItem: NSCollectionViewItem {
    private let thumbnailView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let minimizeButton = NSButton()

    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 6
        thumbnailView.layer?.masksToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        configureButton(closeButton, symbol: "xmark.circle.fill", label: "Close Window", action: #selector(closeTapped))
        configureButton(minimizeButton, symbol: "minus.circle.fill", label: "Minimize Window", action: #selector(minimizeTapped))

        container.addSubview(thumbnailView)
        container.addSubview(titleLabel)
        container.addSubview(closeButton)
        container.addSubview(minimizeButton)

        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            thumbnailView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            thumbnailView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            thumbnailView.heightAnchor.constraint(equalToConstant: 90),

            titleLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),

            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            closeButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            minimizeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            minimizeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            minimizeButton.widthAnchor.constraint(equalToConstant: 18),
            minimizeButton.heightAnchor.constraint(equalToConstant: 18)
        ])
        view = container
    }

    private func configureButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
    }

    func configure(title: String, thumbnail: NSImage?) {
        let resolvedTitle = title.isEmpty ? "Untitled Window" : title
        titleLabel.stringValue = resolvedTitle
        thumbnailView.image = thumbnail
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(resolvedTitle)
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func minimizeTapped() { onMinimize?() }
}
