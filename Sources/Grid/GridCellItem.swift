import AppKit
import Catalog

/// One grid cell: either an app (icon + label) or a folder (folder glyph +
/// name + item count). Both are visually similar on purpose — apps and
/// folders live in the same grid and should read as siblings.
final class GridCellItem: NSCollectionViewItem {
    /// Identifies which record this cell is *currently* configured for.
    /// `NSCollectionView` recycles cell instances across `reloadData()`
    /// calls — a burst of reloads (grid-settings Apply, each search
    /// keystroke) can recycle a cell to a new record before an in-flight
    /// async icon fetch for the *previous* record finishes. Callers set
    /// this synchronously in `configureAsApp`/`configureAsFolder`, then
    /// compare it against the key they captured before the fetch — if it
    /// no longer matches, the cell's been reused and the stale icon must
    /// be dropped, not applied over whatever now belongs there.
    private(set) var currentRequestKey: String?
    private let highlightView = NSView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let countBadge = NSTextField(labelWithString: "")
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

        countBadge.translatesAutoresizingMaskIntoConstraints = false
        countBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        countBadge.textColor = .white
        countBadge.alignment = .center
        countBadge.wantsLayer = true
        countBadge.backgroundColor = .clear
        countBadge.isHidden = true

        // highlightView goes in first so it renders *behind* the icon/label
        // — see `applySelection`'s doc comment for why it's sized to hug
        // the icon+label instead of filling the whole (grid-settings-sized,
        // often much larger than any one icon) cell.
        container.addSubview(highlightView)
        container.addSubview(iconView)
        container.addSubview(label)
        container.addSubview(countBadge)

        let widthConstraint = iconView.widthAnchor.constraint(equalToConstant: 96)
        let heightConstraint = iconView.heightAnchor.constraint(equalToConstant: 96)
        iconWidthConstraint = widthConstraint
        iconHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            widthConstraint,
            heightConstraint,

            countBadge.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -2),
            countBadge.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            countBadge.widthAnchor.constraint(equalToConstant: 18),
            countBadge.heightAnchor.constraint(equalToConstant: 18),

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
        view.wantsLayer = true
    }

    /// Applies `GridSettings.iconSize` — previously hardcoded to 64pt
    /// regardless of the setting, which is why icons rendered noticeably
    /// smaller than intended.
    private func applyIconSize(_ size: Double) {
        let clamped = CGFloat(size)
        iconWidthConstraint?.constant = clamped
        iconHeightConstraint?.constant = clamped
    }

    func configureAsApp(record: ApplicationRecord, icon: NSImage, isSelected: Bool, iconSize: Double, displayName: String? = nil) {
        currentRequestKey = record.iconCacheKey
        applyIconSize(iconSize)
        iconView.image = icon
        let name = displayName ?? record.displayName
        label.stringValue = name
        countBadge.isHidden = true
        applySelection(isSelected)
        // VoiceOver reads the cell as one element ("AppName"), matching how
        // Finder/Launchpad read an app icon — not icon and label separately.
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(name)
    }

    func configureAsFolder(name: String, itemCount: Int, isSelected: Bool, iconSize: Double) {
        // No async icon fetch for folders, but clear this so a pending
        // app-icon task from this cell's *previous* life (if it was an app
        // cell before being recycled into a folder cell) can never match.
        currentRequestKey = nil
        applyIconSize(iconSize)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: iconSize * 0.42, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: name)?
            .withSymbolConfiguration(symbolConfig)
        iconView.contentTintColor = .systemBlue
        label.stringValue = name
        countBadge.stringValue = "\(itemCount)"
        countBadge.isHidden = false
        countBadge.layer?.cornerRadius = 9
        countBadge.layer?.backgroundColor = NSColor.systemRed.cgColor
        applySelection(isSelected)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("\(name) folder, \(itemCount) items")
    }

    /// A soft glass highlight (translucent white fill + thin bright edge)
    /// rather than a flat system-accent block — reads as a piece of the
    /// same glass material lifting slightly, matching how Liquid Glass
    /// surfaces (Control Center's own selection state) highlight rather
    /// than painting a solid color over themselves.
    ///
    /// Drawn on `highlightView` — sized to hug the icon+label, not `view`
    /// (the full collection-view cell). `view` is sized to the grid's
    /// actual per-slot size, which at low column/row counts (or large
    /// configured icon sizes) can be far bigger than the icon it holds;
    /// painting the highlight across the *entire* slot then produces a
    /// large, mostly-empty colored rectangle around a small icon —
    /// confirmed by the user as visibly broken-looking ("これどう見ても
    /// おかしい") via a debug-driven screenshot of a real search result.
    private func applySelection(_ isSelected: Bool) {
        highlightView.layer?.cornerRadius = 12
        highlightView.layer?.backgroundColor = isSelected
            ? NSColor.white.withAlphaComponent(0.14).cgColor
            : NSColor.clear.cgColor
        highlightView.layer?.borderWidth = isSelected ? 1 : 0
        highlightView.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
    }

    /// The icon+label's actual rendered bounds, in this cell's own view
    /// coordinate space. A 7x5 grid's cells are far larger than any one
    /// icon, so treating the *whole cell* as clickable (NSCollectionView's
    /// default) meant clicking what looked like empty space between icons
    /// still launched/selected something — confirmed as a real usability
    /// bug during hands-on testing ("判定がアイコンより大きすぎる"/hit area
    /// is way bigger than the icon). `GridCollectionView` uses this to tell
    /// "really clicked the icon" from "clicked the gap around it," treating
    /// the latter as a background click.
    var contentHitTestFrame: NSRect {
        iconView.frame.union(label.frame)
    }
}
