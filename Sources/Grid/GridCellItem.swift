import AppKit
import Catalog
import Diagnostics
import SwiftUI

/// One grid cell: either an app (icon + label) or a folder (a live-hosted
/// `FolderIconView` SwiftUI view — see that type's doc comment for why
/// this isn't a Core Graphics bitmap — + name). Both are visually similar
/// on purpose — apps and folders live in the same grid and should read as
/// siblings.
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
    /// Hosts `FolderIconView` (real SwiftUI code from the user-supplied
    /// design reference) exactly over `iconView`'s own frame — created
    /// lazily since most cells in a real grid are apps and never need it.
    /// Shown/hidden opposite `iconView` depending on whether this cell is
    /// currently configured as a folder or an app.
    private var folderHostingView: NSHostingView<FolderIconView>?
    private var currentIconSizeValue: CGFloat = 96

    override func loadView() {
        let container = NSView()
        highlightView.translatesAutoresizingMaskIntoConstraints = false
        highlightView.wantsLayer = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // True continuous corner ("squircle"), matching real macOS app icon
        // shape exactly — `NSBezierPath` has no continuous-corner-curve
        // support, so this can only be achieved via `CALayer.cornerCurve`.
        // Real app icons are already squircle-masked in their own asset, so
        // this clip is a visual no-op for them — folders no longer use
        // `iconView` at all (see `folderHostingView`), which gets the true
        // squircle natively via SwiftUI's own `.continuous` style instead.
        iconView.wantsLayer = true
        iconView.layer?.cornerCurve = .continuous
        iconView.layer?.masksToBounds = true

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

    /// Applies `GridViewController.currentIconSize` (a fixed function of
    /// the grid's own row/column geometry — there is no user-adjustable
    /// icon-size setting).
    private func applyIconSize(_ size: Double) {
        let clamped = CGFloat(size)
        currentIconSizeValue = clamped
        iconWidthConstraint?.constant = clamped
        iconHeightConstraint?.constant = clamped
        // 0.236 matches real macOS app icon corner-radius-to-width ratio —
        // recomputed per size change since the corner curve must track the
        // icon's actual current width, not a size set at cell-creation time.
        iconView.layer?.cornerRadius = clamped * 0.236
    }

    /// Creates (once) and positions `folderHostingView` exactly over
    /// `iconView`'s own frame, inserted directly above it in the subview
    /// stack so showing/hiding one vs. the other is a simple `isHidden`
    /// flip with no layout work.
    private func ensureFolderHostingView() -> NSHostingView<FolderIconView> {
        if let existing = folderHostingView { return existing }
        let hosting = NSHostingView(rootView: FolderIconView(icons: [], size: currentIconSizeValue))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.layer?.backgroundColor = .clear
        view.addSubview(hosting, positioned: .above, relativeTo: iconView)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: iconView.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: iconView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: iconView.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: iconView.bottomAnchor)
        ])
        folderHostingView = hosting
        return hosting
    }

    /// - Parameter showsLabel: When `false`, hides and empties the name
    ///   label (an empty, hidden label has 0 intrinsic height, so the
    ///   existing Auto Layout constraints between `iconView`/`label`/
    ///   `container` stay satisfied with no conflicts). No caller currently
    ///   passes `false` — the opened-folder panel now hosts its own SwiftUI
    ///   tile grid (`FolderOverlayTileView`) instead of `GridCellItem`
    ///   directly — but kept as a real, reachable option rather than pruned,
    ///   since a future compact-icon-only presentation of this cell is
    ///   plausible. VoiceOver still announces the name either way
    ///   (`setAccessibilityLabel` is unconditional) since hiding the visible
    ///   label shouldn't hide it from accessibility.
    func configureAsApp(record: ApplicationRecord, icon: NSImage, isSelected: Bool, iconSize: Double, displayName: String? = nil, showsLabel: Bool = true) {
        currentRequestKey = record.iconCacheKey
        applyIconSize(iconSize)
        folderHostingView?.isHidden = true
        iconView.isHidden = false
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

    /// Renders as a Springboard-style folder: a live-hosted `FolderIconView`
    /// (real SwiftUI code from the user-supplied design reference, not a
    /// Core Graphics reinterpretation of its numbers — see that type's doc
    /// comment) — replaces the generic `folder.fill` glyph + red count
    /// badge this app used before Round 12, and every subsequent from-
    /// scratch AppKit attempt at reproducing the reference's look. `icons`
    /// starts empty (renders as an all-placeholder 3x3 grid) until the
    /// caller's own async `IconCache` fetch resolves — see `setFolderIcons`
    /// — using the same `requestKey`/`currentRequestKey` cell-reuse guard
    /// as `configureAsApp`.
    func configureAsFolder(name: String, isSelected: Bool, iconSize: Double, icons: [NSImage], requestKey: String) {
        currentRequestKey = requestKey
        applyIconSize(iconSize)
        iconView.isHidden = true
        let hosting = ensureFolderHostingView()
        hosting.isHidden = false
        hosting.rootView = FolderIconView(icons: icons, size: currentIconSizeValue)
        if ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_FOLDER_FRAME"] == "1" {
            DispatchQueue.main.async {
                DiagnosticsLog.grid.info("folderFrameDebug: iconView.frame=\(String(describing: self.iconView.frame), privacy: .public), hosting.frame=\(String(describing: hosting.frame), privacy: .public), iconSize=\(iconSize, privacy: .public), currentIconSizeValue=\(self.currentIconSizeValue, privacy: .public)")
            }
        }
        label.isHidden = false
        label.stringValue = name
        applySelection(isSelected)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("\(name) folder")
    }

    /// Applies real icons once the caller's own `IconCache` fetches finish
    /// — callers must check `currentRequestKey` against the key they
    /// captured at `configureAsFolder` time first (see that method's doc
    /// comment and this class's `currentRequestKey` doc comment for why).
    func setFolderIcons(_ icons: [NSImage]) {
        folderHostingView?.rootView = FolderIconView(icons: icons, size: currentIconSizeValue)
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
