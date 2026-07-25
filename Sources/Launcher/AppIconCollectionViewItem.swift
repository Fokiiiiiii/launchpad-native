import AppKit
import Catalog

/// A single app cell: icon + label. Built programmatically (no nib) since
/// the whole project avoids Interface Builder per the AppKit-first
/// architecture. The custom paged/vertical grid layout itself is Phase 4 —
/// this item view is what that layout will arrange.
final class AppIconCollectionViewItem: NSCollectionViewItem {
    /// Same cell-reuse guard as `Grid.GridCellItem` — see its doc comment.
    /// Search results reload on every keystroke, which recycles cells even
    /// more aggressively than the main grid does.
    private(set) var currentRequestKey: String?
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?

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

        let widthConstraint = iconView.widthAnchor.constraint(equalToConstant: 64)
        let heightConstraint = iconView.heightAnchor.constraint(equalToConstant: 64)
        iconWidthConstraint = widthConstraint
        iconHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            widthConstraint,
            heightConstraint,

            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -4)
        ])
        view = container
    }

    /// Matches `Grid.GridCellItem`'s handling of `GridSettings.iconSize` —
    /// this item was previously hardcoded to 64pt regardless of the user's
    /// configured grid icon size, so search results rendered at a visibly
    /// different (and, at large configured sizes, jarringly smaller) size
    /// than the main grid the moment a query was typed.
    func configure(record: ApplicationRecord, icon: NSImage, isSelected: Bool, iconSize: Double) {
        currentRequestKey = record.iconCacheKey
        iconWidthConstraint?.constant = CGFloat(iconSize)
        iconHeightConstraint?.constant = CGFloat(iconSize)
        iconView.image = icon
        label.stringValue = record.displayName
        view.layer?.cornerRadius = 12
        view.wantsLayer = true
        view.layer?.backgroundColor = isSelected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor
            : NSColor.clear.cgColor
    }
}
