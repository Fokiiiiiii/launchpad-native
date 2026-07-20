import AppKit
import Catalog

/// One grid cell: either an app (icon + label) or a folder (folder glyph +
/// name + item count). Both are visually similar on purpose — apps and
/// folders live in the same grid and should read as siblings.
final class GridCellItem: NSCollectionViewItem {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let countBadge = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2

        countBadge.translatesAutoresizingMaskIntoConstraints = false
        countBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        countBadge.textColor = .white
        countBadge.alignment = .center
        countBadge.wantsLayer = true
        countBadge.backgroundColor = .clear
        countBadge.isHidden = true

        container.addSubview(iconView)
        container.addSubview(label)
        container.addSubview(countBadge)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            countBadge.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -2),
            countBadge.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            countBadge.widthAnchor.constraint(equalToConstant: 18),
            countBadge.heightAnchor.constraint(equalToConstant: 18),

            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -4)
        ])
        view = container
        view.wantsLayer = true
    }

    func configureAsApp(record: ApplicationRecord, icon: NSImage, isSelected: Bool) {
        iconView.image = icon
        label.stringValue = record.displayName
        countBadge.isHidden = true
        applySelection(isSelected)
    }

    func configureAsFolder(name: String, itemCount: Int, isSelected: Bool) {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: name)?
            .withSymbolConfiguration(symbolConfig)
        iconView.contentTintColor = .systemBlue
        label.stringValue = name
        countBadge.stringValue = "\(itemCount)"
        countBadge.isHidden = false
        countBadge.layer?.cornerRadius = 9
        countBadge.layer?.backgroundColor = NSColor.systemRed.cgColor
        applySelection(isSelected)
    }

    private func applySelection(_ isSelected: Bool) {
        view.layer?.cornerRadius = 12
        view.layer?.backgroundColor = isSelected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor
            : NSColor.clear.cgColor
    }
}
