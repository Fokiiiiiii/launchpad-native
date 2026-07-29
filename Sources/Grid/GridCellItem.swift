import AppKit
import Catalog

/// One grid cell: either an app (icon + label) or a folder (a composited,
/// count-adaptive preview tile of the folder's own contents, built by
/// `FolderIconComposer`, + name). Both are visually similar on purpose —
/// apps and folders live in the same grid and should read as siblings.
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
        // — see `applySelection`'s doc comment for why it's sized to hug
        // the icon+label instead of filling the whole (grid-settings-sized,
        // often much larger than any one icon) cell.
        container.addSubview(highlightView)
        container.addSubview(iconView)
        container.addSubview(label)

        let widthConstraint = iconView.widthAnchor.constraint(equalToConstant: 96)
        let heightConstraint = iconView.heightAnchor.constraint(equalToConstant: 96)
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
        view.wantsLayer = true
    }

    /// Defense-in-depth against stale visual state surviving `NSCollectionView`'s
    /// cell-reuse recycling: `reloadData()`/`makeItem(withIdentifier:for:)`
    /// reuse view instances without resetting any `CALayer` state on their
    /// own, and neither `configureAsApp`/`configureAsFolder` below touch
    /// `transform`/animations/`isHidden`. The item-drag machinery in
    /// `GridViewController` already resets these explicitly on every known
    /// exit path, but this closes the gap structurally — a recycled cell
    /// can never inherit a leftover offset, animation, or hidden state from
    /// whatever index path it previously represented.
    override func prepareForReuse() {
        super.prepareForReuse()
        view.layer?.removeAllAnimations()
        view.layer?.transform = CATransform3DIdentity
        view.isHidden = false
        view.layer?.opacity = 1
    }

    /// Applies `GridSettings.iconSize` — previously hardcoded to 64pt
    /// regardless of the setting, which is why icons rendered noticeably
    /// smaller than intended.
    private func applyIconSize(_ size: Double) {
        let clamped = CGFloat(size)
        iconWidthConstraint?.constant = clamped
        iconHeightConstraint?.constant = clamped
    }

    /// - Parameter showsLabel: When `false`, hides and empties the name
    ///   label (an empty, hidden label has 0 intrinsic height, so the
    ///   existing Auto Layout constraints between `iconView`/`label`/
    ///   `container` stay satisfied with no conflicts) — used by
    ///   `FolderContentsViewController`'s compact icon-only popover cells,
    ///   where the folder's name is already shown once above the grid.
    ///   VoiceOver still announces the name either way (`setAccessibilityLabel`
    ///   is unconditional) since hiding the visible label shouldn't hide it
    ///   from accessibility.
    func configureAsApp(record: ApplicationRecord, icon: NSImage, isSelected: Bool, iconSize: Double, displayName: String? = nil, showsLabel: Bool = true) {
        currentRequestKey = record.iconCacheKey
        applyIconSize(iconSize)
        iconView.image = icon
        let name = displayName ?? record.displayName
        if showsLabel {
            label.isHidden = false
            label.stringValue = name
        } else {
            label.isHidden = true
            label.stringValue = ""
        }
        applySelection(isSelected)
        // VoiceOver reads the cell as one element ("AppName"), matching how
        // Finder/Launchpad read an app icon — not icon and label separately.
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(name)
    }

    /// Renders as a Springboard-style folder: a composited preview tile of
    /// up to 9 of the folder's own app icons, arranged in a grid shape that
    /// adapts to the folder's actual app count (see
    /// `FolderIconComposer.gridShape(forIconCount:)`) — replaces the
    /// generic `folder.fill` glyph + red count badge this app used before
    /// Round 12, and Round 12's own fixed-3x3-regardless-of-count layout
    /// before Round 14. The thumbnail is supplied by the caller
    /// (`thumbnail`, possibly `nil` for "not ready yet" — see
    /// `setFolderThumbnail`) rather than composited in here, since building
    /// it requires each app icon from `IconCache`, which callers already
    /// fetch asynchronously with their own cell-reuse guard (`requestKey`,
    /// same pattern as `configureAsApp`'s `currentRequestKey`).
    func configureAsFolder(name: String, isSelected: Bool, iconSize: Double, thumbnail: NSImage?, requestKey: String) {
        currentRequestKey = requestKey
        applyIconSize(iconSize)
        iconView.contentTintColor = nil
        iconView.image = thumbnail ?? FolderIconComposer.placeholderTile(size: iconSize)
        label.isHidden = false
        label.stringValue = name
        applySelection(isSelected)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("\(name) folder")
    }

    /// Applies a folder thumbnail once `FolderIconComposer` finishes
    /// compositing it asynchronously — callers must check
    /// `currentRequestKey` against the key they captured at `configureAsFolder`
    /// time first (see that method's doc comment and this class's
    /// `currentRequestKey` doc comment for why).
    func setFolderThumbnail(_ image: NSImage) {
        iconView.image = image
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
    /// Not `private`: `GridViewController`'s item-drag press feedback calls
    /// this directly on the already-existing cell view, instead of going
    /// through `collectionView.reloadItems(at:)` — see that call site's doc
    /// comment for why `reloadItems` specifically must not be called from
    /// inside a mouseDown handler for the same item.
    func applySelection(_ isSelected: Bool) {
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
    ///
    /// The label's own `frame` is pinned edge-to-edge across the full cell
    /// width (see the leading/trailing constraints above), so unioning it
    /// as-is would make a short app name's hit region span the entire
    /// cell's width, not just the name's own rendered text — capped to the
    /// label's actual rendered text width instead (falling back to the
    /// icon's width for an empty/hidden label, e.g. `showsLabel: false`).
    var contentHitTestFrame: NSRect {
        let iconFrame = iconView.frame
        let textWidth = min(label.attributedStringValue.size().width, label.frame.width)
        let hitWidth = max(textWidth, iconFrame.width)
        let labelRect = NSRect(x: label.frame.midX - hitWidth / 2, y: label.frame.minY, width: hitWidth, height: label.frame.height)
        return iconFrame.union(labelRect)
    }
}
