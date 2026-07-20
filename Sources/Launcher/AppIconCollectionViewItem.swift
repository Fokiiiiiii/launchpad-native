import AppKit
import Catalog

/// A single app cell: icon + label. Built programmatically (no nib) since
/// the whole project avoids Interface Builder per the AppKit-first
/// architecture. The custom paged/vertical grid layout itself is Phase 4 —
/// this item view is what that layout will arrange.
final class AppIconCollectionViewItem: NSCollectionViewItem {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

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

        container.addSubview(iconView)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -4)
        ])
        view = container
    }

    func configure(record: ApplicationRecord, icon: NSImage, isSelected: Bool) {
        iconView.image = icon
        label.stringValue = record.displayName
        view.layer?.cornerRadius = 12
        view.wantsLayer = true
        view.layer?.backgroundColor = isSelected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor
            : NSColor.clear.cgColor
    }
}
