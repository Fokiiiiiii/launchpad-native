import AppKit
import DesignSystem
import Catalog
import Diagnostics
import Localization
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
    private var highlightInsets: [NSLayoutConstraint] = []
    private var iconHeightConstraint: NSLayoutConstraint?
    private var iconTopConstraint: NSLayoutConstraint?
    private var folderHostingView: NSHostingView<FolderIconView>?
    /// Base size supplied by the grid before the user's scale is applied.
    private var currentIconSizeValue: CGFloat = 96
    /// Effective size used by Auto Layout. Keeping the scale in the actual
    /// constraint makes the label move with the icon instead of remaining
    /// attached to the pre-scale frame.
    private var displayedIconSizeValue: CGFloat = 96

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
        label.maximumNumberOfLines = 1
        label.wantsLayer = true
        label.layer?.shadowColor = NSColor.black.cgColor
        label.layer?.shadowOpacity = 0.55
        label.layer?.shadowRadius = 2
        label.layer?.shadowOffset = CGSize(width: 0, height: -1)

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
        let iconTop = iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 2)
        iconTopConstraint = iconTop
        // The configured scale may use the vertical spacing between rows. A
        // low-priority bottom guard lets the centered icon+label group extend
        // into that gap instead of forcing Auto Layout to clip the label.
        let labelBottom = label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -1)
        labelBottom.priority = .defaultLow

        NSLayoutConstraint.activate([
            iconTop,
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            widthConstraint,
            heightConstraint,

            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 5),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            labelBottom
        ])

        // A square around the icon alone, not a band around icon and label:
        // the selection should read as the icon sitting on a tile, the way a
        // focused icon does elsewhere on the system. The insets track the icon
        // size, so the tile keeps its proportions as the grid is resized.
        let highlightInsets = [
            highlightView.topAnchor.constraint(equalTo: iconView.topAnchor),
            highlightView.bottomAnchor.constraint(equalTo: iconView.bottomAnchor),
            highlightView.leadingAnchor.constraint(equalTo: iconView.leadingAnchor),
            highlightView.trailingAnchor.constraint(equalTo: iconView.trailingAnchor)
        ]
        self.highlightInsets = highlightInsets
        NSLayoutConstraint.activate(highlightInsets)
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
        resetVisualTransforms()
        currentRequestKey = nil
        iconView.image = nil
        label.stringValue = ""
        currentIconSizeValue = 96
        displayedIconSizeValue = 96
        folderHostingView?.isHidden = true
        folderHostingView?.rootView = FolderIconView(icons: [], size: displayedIconSizeValue)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let spacing: CGFloat = label.isHidden ? 0 : 5
        let labelHeight = label.isHidden ? 0 : max(label.intrinsicContentSize.height, 0)
        let groupHeight = displayedIconSizeValue + spacing + labelHeight
        let centeredTop = max(2, (view.bounds.height - groupHeight) / 2)
        if abs((iconTopConstraint?.constant ?? 2) - centeredTop) > 0.5 {
            iconTopConstraint?.constant = centeredTop
        }
        resetVisualTransforms()
    }

    /// Re-applies the icon geometry to an already-configured cell.
    ///
    /// `configure…` bakes in whatever size was current when the cell was built.
    /// A cell built before the layout settled keeps that size until the next
    /// `reloadData()` — on a cold start, the catalog scan a second or two later
    /// — so the icons visibly shrink long after the window is up. Reports
    /// whether anything changed, so the caller can skip an extra layout pass.
    @discardableResult
    func refreshIconSize(_ size: Double, visualScale: Double) -> Bool {
        let previous = displayedIconSizeValue
        applyIconSize(size, visualScale: visualScale)
        guard abs(displayedIconSizeValue - previous) > 0.5 else { return false }
        if let hosting = folderHostingView, !hosting.isHidden {
            // The folder mosaic is SwiftUI and takes its size as a value, not
            // from the Auto Layout constraints `applyIconSize` just updated.
            hosting.rootView = FolderIconView(icons: hosting.rootView.icons, size: displayedIconSizeValue)
        }
        return true
    }

    /// Applies the effective size to the icon constraint itself. The previous
    /// layer-only scale changed the picture but left the label attached to the
    /// old frame, so changing the setting appeared to leave text in place.
    private func applyIconSize(_ size: Double, visualScale: Double) {
        let clamped = CGFloat(size)
        currentIconSizeValue = clamped
        let scale = min(max(CGFloat(visualScale), 0.9), 1.2)
        displayedIconSizeValue = clamped * scale
        iconWidthConstraint?.constant = displayedIconSizeValue
        iconHeightConstraint?.constant = displayedIconSizeValue
        // 0.236 matches real macOS app icon corner-radius-to-width ratio —
        // recomputed per size change since the corner curve must track the
        // icon's actual current width, not a size set at cell-creation time.
        iconView.layer?.cornerRadius = displayedIconSizeValue * 0.236
        applyHighlightGeometry()
        view.needsLayout = true
    }

    /// The selection tile, sized from the artwork inside the icon view rather
    /// than from the view's own frame — see `SelectionHighlight.tileGeometry`.
    private func applyHighlightGeometry() {
        let tile = SelectionHighlight.tileGeometry(iconViewSide: displayedIconSizeValue)
        // top/leading move inward as positives; bottom/trailing as negatives.
        highlightInsets[0].constant = tile.inset
        highlightInsets[1].constant = -tile.inset
        highlightInsets[2].constant = tile.inset
        highlightInsets[3].constant = -tile.inset
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = tile.cornerRadius
        highlightView.layer?.cornerCurve = .continuous
    }

    /// The effective size is expressed by Auto Layout, so every path that
    /// configures or recycles this cell clears the layer transforms rather
    /// than setting one — a leftover transform would scale an already-sized
    /// cell a second time.
    private func resetVisualTransforms() {
        resetTransform(for: iconView)
        if let folderHostingView {
            resetTransform(for: folderHostingView)
        }
        resetTransform(for: highlightView)
    }

    private func resetTransform(for targetView: NSView) {
        targetView.layer?.removeAllAnimations()
        targetView.layer?.setAffineTransform(.identity)
    }

    /// Creates (once) and positions `folderHostingView` exactly over
    /// `iconView`'s own frame, inserted directly above it in the subview
    /// stack so showing/hiding one vs. the other is a simple `isHidden`
    /// flip with no layout work.
    private func ensureFolderHostingView() -> NSHostingView<FolderIconView> {
        if let existing = folderHostingView { return existing }
        let hosting = NSHostingView(rootView: FolderIconView(icons: [], size: displayedIconSizeValue))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.clipsToBounds = false
        hosting.layer?.masksToBounds = false
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

    /// - Parameter showsLabel: when `false`, empties and hides the label (an
    ///   empty hidden label has no intrinsic height, so the constraints stay
    ///   satisfied). No caller passes `false` today; VoiceOver announces the
    ///   name either way.
    func configureAsApp(record: ApplicationRecord, icon: NSImage, isSelected: Bool, iconSize: Double, visualScale: Double = 1, displayName: String? = nil, showsLabel: Bool = true) {
        currentRequestKey = record.iconCacheKey
        applyIconSize(iconSize, visualScale: visualScale)
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
        view.setAccessibilitySelected(isSelected)
        view.setAccessibilityValue(isSelected ? L10n.selectedAccessibilityValue : nil)
        resetVisualTransforms()
    }

    func configureAsFolder(name: String, isSelected: Bool, iconSize: Double, visualScale: Double = 1, icons: [NSImage], requestKey: String) {
        currentRequestKey = requestKey
        applyIconSize(iconSize, visualScale: visualScale)
        iconView.isHidden = true
        let hosting = ensureFolderHostingView()
        hosting.isHidden = false
        hosting.rootView = FolderIconView(icons: icons, size: displayedIconSizeValue)
        hosting.layoutSubtreeIfNeeded()
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
        view.setAccessibilitySelected(isSelected)
        view.setAccessibilityValue(isSelected ? L10n.selectedAccessibilityValue : nil)
        resetVisualTransforms()
    }

    /// Applies real icons once the caller's own `IconCache` fetches finish
    /// — callers must check `currentRequestKey` against the key they
    /// captured at `configureAsFolder` time first (see that method's doc
    /// comment and this class's `currentRequestKey` doc comment for why).
    func setFolderIcons(_ icons: [NSImage]) {
        folderHostingView?.rootView = FolderIconView(icons: icons, size: displayedIconSizeValue)
        folderHostingView?.layoutSubtreeIfNeeded()
        resetVisualTransforms()
    }

    func applySelection(_ isSelected: Bool) {
        SelectionHighlight.apply(to: highlightView, isSelected: isSelected)
    }

    /// Test hook: the selection tile's own frame, for checking it stays a
    /// square around the icon as the grid is resized.
    var selectionTileFrameForTesting: NSRect? {
        highlightView.layer?.backgroundColor.flatMap { $0.alpha > 0 ? highlightView.frame : nil }
    }

    var iconFrame: NSRect {
        iconView.frame
    }

    var contentHitTestFrame: NSRect {
        let iconFrame = self.iconFrame
        let textWidth = min(label.attributedStringValue.size().width, label.frame.width)
        let hitWidth = max(textWidth, iconFrame.width)
        let labelRect = NSRect(x: label.frame.midX - hitWidth / 2, y: label.frame.minY, width: hitWidth, height: label.frame.height)
        return iconFrame.union(labelRect)
    }
}
