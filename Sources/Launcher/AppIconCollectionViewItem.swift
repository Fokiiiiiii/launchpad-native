import AppKit
import DesignSystem
import Catalog
import Localization

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
    private var highlightInsets: [NSLayoutConstraint] = []
    private var iconHeightConstraint: NSLayoutConstraint?
    private var iconTopConstraint: NSLayoutConstraint?
    private var displayedIconSize: CGFloat = 64

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
        label.maximumNumberOfLines = 1
        label.wantsLayer = true
        label.layer?.shadowColor = NSColor.black.cgColor
        label.layer?.shadowOpacity = 0.55
        label.layer?.shadowRadius = 2
        label.layer?.shadowOffset = CGSize(width: 0, height: -1)

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
        let iconTop = iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 2)
        iconTopConstraint = iconTop
        // The shared icon scale can use the vertical spacing between search
        // cells. Keep the bottom guard as a soft constraint so the label
        // follows the centered group instead of being clipped at the old
        // unscaled cell boundary.
        let labelBottom = label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -1)
        labelBottom.priority = .defaultLow

        NSLayoutConstraint.activate([
            iconTop,
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            widthConstraint,
            heightConstraint,

            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            labelBottom,

        ])

        // Same tile as the main grid's — arrow keys move between the two, and
        // a selection that changed shape on the way would read as a different
        // kind of selection.
        let highlightInsets = [
            highlightView.topAnchor.constraint(equalTo: iconView.topAnchor),
            highlightView.bottomAnchor.constraint(equalTo: iconView.bottomAnchor),
            highlightView.leadingAnchor.constraint(equalTo: iconView.leadingAnchor),
            highlightView.trailingAnchor.constraint(equalTo: iconView.trailingAnchor)
        ]
        self.highlightInsets = highlightInsets
        NSLayoutConstraint.activate(highlightInsets)
        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let labelHeight = max(label.intrinsicContentSize.height, 0)
        let groupHeight = displayedIconSize + 4 + labelHeight
        let centeredTop = max(2, (view.bounds.height - groupHeight) / 2)
        if abs((iconTopConstraint?.constant ?? 2) - centeredTop) > 0.5 {
            iconTopConstraint?.constant = centeredTop
        }
        applyVisualTransforms()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentRequestKey = nil
        iconView.image = nil
        label.stringValue = ""
        displayedIconSize = 64
        iconWidthConstraint?.constant = displayedIconSize
        iconHeightConstraint?.constant = displayedIconSize
        applyHighlightGeometry()
        view.layer?.removeAllAnimations()
        view.layer?.setAffineTransform(.identity)
        view.layer?.opacity = 1
        view.isHidden = false
        applyVisualTransforms()
    }

    /// The selection tile, sized from the icon it sits behind. Kept in step
    /// with the main grid's own proportions.
    private func applyHighlightGeometry() {
        let tile = SelectionHighlight.tileGeometry(iconViewSide: displayedIconSize)
        highlightInsets[0].constant = tile.inset
        highlightInsets[1].constant = -tile.inset
        highlightInsets[2].constant = tile.inset
        highlightInsets[3].constant = -tile.inset
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = tile.cornerRadius
        highlightView.layer?.cornerCurve = .continuous
    }

    /// Matches `Grid.GridCellItem`'s icon sizing — this item was previously
    /// hardcoded to 64pt regardless of the main grid's actual icon size (a
    /// fixed function of the row/column geometry), so search results
    /// rendered at a visibly different size than the main grid the moment a
    /// query was typed.
    /// `displayName` is passed in rather than read off the record: a renamed
    /// app carries its new name in `GridModel`'s aliases, not in the catalog,
    /// and the grid and folder panel both go through `GridModel.displayName`.
    /// This list showing the catalog name instead was how a rename made from
    /// the search results looked like it had done nothing at all.
#if LAUNCHPAD_DEBUG_HOOKS
    /// What this cell is actually showing — see the search hooks in
    /// `LauncherViewController`.
    var debugLabelText: String { label.stringValue }
    #endif

    func configure(record: ApplicationRecord, icon: NSImage, isSelected: Bool, iconSize: Double, visualScale: Double = 1, displayName: String? = nil) {
        currentRequestKey = record.iconCacheKey
        let baseSize = CGFloat(iconSize)
        let scale = min(max(CGFloat(visualScale), 0.9), 1.2)
        displayedIconSize = baseSize * scale
        iconWidthConstraint?.constant = displayedIconSize
        iconHeightConstraint?.constant = displayedIconSize
        applyHighlightGeometry()
        iconView.image = icon
        let name = displayName ?? record.displayName
        label.stringValue = name
        view.wantsLayer = true
        applySelection(isSelected)
        // Expose the same single, actionable element as the main grid so
        // VoiceOver reads the app name, role, and keyboard selection state.
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(name)
        view.setAccessibilitySelected(isSelected)
        view.setAccessibilityValue(isSelected ? L10n.selectedAccessibilityValue : nil)
        applyVisualTransforms()
    }

    /// Matches `Grid.GridCellItem.applySelection` exactly, including drawing
    /// on `highlightView` (hugging the icon) rather than the full `view`
    /// (the whole grid-cell-sized slot). A debug-driven screenshot of a
    /// real search result ("これどう見てもおかしい") showed this cell's
    /// selection filling nearly its entire ~290x285pt slot around a much
    /// smaller icon — a large, mostly-empty highlighted rectangle. Fixed
    /// the same way as `GridCellItem`: see its `applySelection` doc comment.
    private func applySelection(_ isSelected: Bool) {
        SelectionHighlight.apply(to: highlightView, isSelected: isSelected)
    }

    private var renderedIconFrame: NSRect {
        iconView.frame
    }

    private func applyVisualTransforms() {
        iconView.layer?.removeAllAnimations()
        iconView.layer?.setAffineTransform(.identity)
        highlightView.layer?.removeAllAnimations()
        highlightView.layer?.setAffineTransform(.identity)
    }

    /// Same reasoning as `Grid.GridCellItem.contentHitTestFrame`: a search
    /// result's cell slot is sized to the grid's real per-cell size (often
    /// far larger than the icon it holds — see `LauncherViewController`'s
    /// `applySearchResultsLayoutMetrics`), so treating the whole cell as
    /// clickable would let clicks in the visibly-empty margin around the
    /// icon still select/launch something. `SearchResultsCollectionView`
    /// uses this the same way `GridCollectionView` uses `GridCellItem`'s.
    var contentHitTestFrame: NSRect {
        let iconFrame = renderedIconFrame
        let textWidth = min(label.attributedStringValue.size().width, label.frame.width)
        let hitWidth = max(textWidth, iconFrame.width)
        let labelRect = NSRect(
            x: label.frame.midX - hitWidth / 2,
            y: label.frame.minY,
            width: hitWidth,
            height: label.frame.height
        )
        return iconFrame.union(labelRect)
    }
}
