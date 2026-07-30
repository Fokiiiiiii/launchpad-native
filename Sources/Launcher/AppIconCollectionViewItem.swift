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
    private let highlightView = NSView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?

    override func loadView() {
        let container = NSView()
        highlightView.translatesAutoresizingMaskIntoConstraints = false
        highlightView.wantsLayer = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2

        // highlightView goes in first so it renders *behind* the icon/label
        // — see `applySelection`'s doc comment for why it hugs the icon
        // instead of filling the whole (grid-cell-sized, often much larger
        // than the icon) cell.
        container.addSubview(highlightView)
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
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -4),

            highlightView.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -8),
            highlightView.bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            highlightView.leadingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -16),
            highlightView.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16)
        ])
        view = container
    }

    /// Matches `Grid.GridCellItem`'s icon sizing — this item was previously
    /// hardcoded to 64pt regardless of the main grid's actual icon size (a
    /// fixed function of the row/column geometry), so search results
    /// rendered at a visibly different size than the main grid the moment a
    /// query was typed.
    func configure(record: ApplicationRecord, icon: NSImage, isSelected: Bool, iconSize: Double) {
        currentRequestKey = record.iconCacheKey
        iconWidthConstraint?.constant = CGFloat(iconSize)
        iconHeightConstraint?.constant = CGFloat(iconSize)
        iconView.image = icon
        label.stringValue = record.displayName
        view.wantsLayer = true
        applySelection(isSelected)
    }

    /// Matches `Grid.GridCellItem.applySelection` exactly, including drawing
    /// on `highlightView` (hugging the icon) rather than the full `view`
    /// (the whole grid-cell-sized slot). A debug-driven screenshot of a
    /// real search result ("これどう見てもおかしい") showed this cell's
    /// selection filling nearly its entire ~290x285pt slot around a much
    /// smaller icon — a large, mostly-empty highlighted rectangle. Fixed
    /// the same way as `GridCellItem`: see its `applySelection` doc comment.
    private func applySelection(_ isSelected: Bool) {
        highlightView.layer?.cornerRadius = 12
        highlightView.layer?.backgroundColor = isSelected
            ? NSColor.white.withAlphaComponent(0.14).cgColor
            : NSColor.clear.cgColor
        highlightView.layer?.borderWidth = isSelected ? 1 : 0
        highlightView.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
    }

    /// Same reasoning as `Grid.GridCellItem.contentHitTestFrame`: a search
    /// result's cell slot is sized to the grid's real per-cell size (often
    /// far larger than the icon it holds — see `LauncherViewController`'s
    /// `applySearchResultsLayoutMetrics`), so treating the whole cell as
    /// clickable would let clicks in the visibly-empty margin around the
    /// icon still select/launch something. `SearchResultsCollectionView`
    /// uses this the same way `GridCollectionView` uses `GridCellItem`'s.
    var contentHitTestFrame: NSRect {
        iconView.frame.union(label.frame)
    }
}
