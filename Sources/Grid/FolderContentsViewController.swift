import AppKit
import Catalog
import Persistence
import SwiftUI

/// Shown inside a full-screen dimming backdrop when a folder is opened
/// (`GridViewController.openFolder`/`FolderOverlayBackdropView`) — this
/// controller only owns its own content (title + tile grid + glass card
/// background); the full-screen take-over presentation is entirely the
/// caller's concern. Folder-internal paging (`Folder.pages`) is flattened to
/// one scrollable list here — the data model still tracks per-page ordering
/// (needed for legacy import fidelity), but a folder rarely holds enough
/// items to need its own paging UI, so this is a deliberate simplification,
/// not a data loss.
///
/// The tile grid itself is real SwiftUI (`FolderOverlayGridContent`/
/// `FolderOverlayTileView`, hosted via `NSHostingView`), directly adapted
/// from the user-supplied "Tessera" design reference's own `FolderOverlay`/
/// `AppTile` — not a hand-translated AppKit/`NSCollectionView` reinterpretation
/// of its numbers. This follows the same lesson already applied to the
/// closed folder icon (`FolderIconView`): tuning AppKit geometry to
/// *approximate* the reference repeatedly fell short of the user's explicit
/// "寸分違わず同じものにできないの？" (can't you make it exactly,
/// pixel-for-pixel identical to the reference?) ask, whereas hosting the
/// reference's actual view code is identical by construction.
final class FolderContentsViewController: NSViewController {
    private let model: GridModel
    private let folderID: FolderID
    private let iconCache: IconCache
    private let onLaunch: (ApplicationRecord) -> Void
    private let onItemDraggedOut: (Int, Int) -> Void

    private let titleField = NSTextField(labelWithString: "")
    private let gridModel = FolderOverlayGridModel()
    /// The main grid's own current icon size (`GridViewController.currentIconSize`)
    /// — a real design reference the user supplied directly asked for
    /// "内部アイコンが通常サイズの配置へ広がる" (contained icons expand to
    /// their normal size when the folder opens), which a fixed 56pt
    /// regardless of the grid's actual configured size did not satisfy.
    private let iconSize: Double
    /// The main grid's own column count (`GridSettings.columns`) — a real
    /// screenshot of a genuinely different app (confirmed by the user;
    /// its "その他" folder held system utilities that don't match this
    /// app's own data at all) showed the opened folder always using the
    /// *same* fixed column count as the closed grid itself, with rows
    /// growing/shrinking to fit — not a variable column count computed
    /// from the item count (this file's previous `sqrt(itemCount * 1.6)`
    /// heuristic), which the reference never does
    /// (`LazyVGrid(columns: Array(repeating: ..., count: metrics.columns))`
    /// — always exactly `metrics.columns`).
    private let columns: Int
    /// The full outer card width the caller wants (`GridViewController.openFolder`
    /// computes this as `screenWidth - 192`, matching the reference's own
    /// `.padding(.horizontal, TSLayout.folderPanelInsetH)`), fed into
    /// `preferredContentSize.width` by `updatePreferredContentSize()` below
    /// so the caller can read it back via `preferredContentSize` without
    /// duplicating the row/height math this controller owns. See
    /// `loadView()`'s doc comment for why `root`'s own outer frame is set
    /// directly by the caller rather than via Auto Layout constraints.
    private let panelWidth: CGFloat
    /// Matches the "Tessera" design reference's `LazyVGrid(..., spacing: 26)`
    /// exactly — the previous 16pt was an invented value, not taken from
    /// the reference.
    private static let cellSpacing: CGFloat = 26
    private var itemHeight: CGFloat { CGFloat(iconSize) + 40 }

    /// Flattened (folderPage, folderIndex, item) so "Remove from Folder" can
    /// address the exact underlying position.
    private var flattenedItems: [(page: Int, index: Int, item: LayoutItem)] = []
    /// Bumped on every `refresh()`; guards a still-in-flight async icon
    /// fetch from writing into `gridModel.tiles` after a *later* refresh
    /// has already replaced the array (same purpose as the
    /// `currentRequestKey` guard `GridCellItem` uses for cell reuse, but
    /// keyed to this controller's own single shared tile array instead of
    /// per-cell identity).
    private var refreshGeneration = 0

    init(
        model: GridModel,
        folderID: FolderID,
        iconCache: IconCache,
        iconSize: Double,
        columns: Int,
        panelWidth: CGFloat,
        onLaunch: @escaping (ApplicationRecord) -> Void,
        onItemDraggedOut: @escaping (Int, Int) -> Void
    ) {
        self.model = model
        self.folderID = folderID
        self.iconCache = iconCache
        self.iconSize = iconSize
        self.columns = max(columns, 1)
        self.panelWidth = max(panelWidth, 240)
        self.onLaunch = onLaunch
        self.onItemDraggedOut = onItemDraggedOut
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func loadView() {
        let root = NSView()
        // `root`'s own outer frame is deliberately plain/frame-based (this
        // is the default — `translatesAutoresizingMaskIntoConstraints`
        // stays `true`), never Auto Layout, and the caller
        // (`GridViewController.openFolder`) sets `root.frame` directly
        // rather than via constraints. This sidesteps a real, confirmed
        // AppKit behavior: when a view controller's view *does* use pure
        // Auto Layout for its own outer geometry, `NSViewController`
        // automatically maintains its own width/height constraints mirroring
        // `preferredContentSize` (visible in a live constraint dump as
        // `'NSViewController.preferredContentSize.width'`) — and in one
        // confirmed real regression ("フォルダを開くと画面が半分になる" /
        // "フォルダのみためがひどすぎる"), that auto-mirrored constraint
        // intermittently won over an explicit, equal-or-higher-priority
        // caller-side constraint for `root`'s width, leaving the panel
        // rendered at its SwiftUI content's own narrower intrinsic size
        // instead of the intended screen-relative width — reproducibly, on
        // a fresh rebuild, regardless of priority tuning or explicitly
        // deactivating that constraint after the fact (both tried; neither
        // held). Never having `root` participate in Auto Layout for its own
        // frame in the first place removes the interaction entirely: Auto
        // Layout still governs everything *inside* `root` (background/
        // titleField/scrollView/hosting, all pinned to `root`'s bounds),
        // which works identically regardless of whether `root` itself is
        // frame- or constraint-positioned by its own superview.

        // Dark, styled card background — a decorative sibling behind the
        // title/grid, matching the reference's self-contained floating
        // card. Corner radius (34) matches the "Tessera" design reference's
        // own folder panel exactly.
        let background = GlassBackgroundHelper.makeBackground(cornerRadius: 34, dark: true)
        background.translatesAutoresizingMaskIntoConstraints = false

        titleField.translatesAutoresizingMaskIntoConstraints = false
        // 21pt regular weight — the reference's own
        // `Text(folder.name).font(.system(size: TSLayout.folderTitleSize))`
        // has no explicit weight (defaults to regular).
        titleField.font = .systemFont(ofSize: 21, weight: .regular)
        titleField.alignment = .center
        // Matches the reference's own `.shadow(color: .black.opacity(0.5),
        // radius: 8, y: 2)` on the title text — AppKit's y-offset convention
        // is flipped relative to SwiftUI's (positive = up), so -2 here is
        // the same downward-cast shadow.
        let titleShadow = NSShadow()
        titleShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        titleShadow.shadowBlurRadius = 8
        titleShadow.shadowOffset = NSSize(width: 0, height: -2)
        titleField.shadow = titleShadow

        let hosting = NSHostingView(rootView: FolderOverlayGridContent(model: gridModel, columns: columns, iconSize: CGFloat(iconSize)))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // Defense in depth alongside the explicit widthAnchor below and the
        // forced layoutIfNeeded() calls in refresh() — never let SwiftUI's
        // own intrinsic-size measurement win a priority tie-break against
        // the imposed Auto Layout width.
        hosting.setContentCompressionResistancePriority(.required, for: .horizontal)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        root.addSubview(background)
        root.addSubview(titleField)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: root.topAnchor),
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            titleField.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            titleField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            // 28pt — the reference's own `VStack(spacing: 28)` wrapping the
            // title and grid; the previous 8pt was an invented value.
            scrollView.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 28),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            // Pinned to `scrollView.contentView` (the NSClipView), not
            // `scrollView` itself — the documented-correct anchor target
            // for a constraint-based documentView. Anchoring to the scroll
            // view directly (two levels above hosting's actual superview)
            // previously left NSHostingView without a firm width proposal,
            // so SwiftUI fell back to its own intrinsic-size measurement
            // and the whole panel rendered as a collapsed, narrow column —
            // a real screenshot showed the folder as a garbled vertical
            // sliver instead of a wide grid. The explicit widthAnchor is
            // redundant with leading+trailing (consistent, not
            // conflicting) but makes the firm-width requirement explicit.
            hosting.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hosting.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        view = root
        refresh()
    }

    /// Computes `preferredContentSize` — width is always exactly `panelWidth`
    /// (the caller's target, see its doc comment for why this must match
    /// exactly); only the height is derived here, from the fixed `columns`
    /// count (the main grid's own column count — see that property's doc
    /// comment for why this isn't a per-item-count heuristic) and the actual
    /// row count (up to the 480pt/scrolling cap).
    private func updatePreferredContentSize() {
        let itemCount = max(flattenedItems.count, 1)
        let rows = max(1, Int(ceil(Double(itemCount) / Double(columns))))
        let cellHeight = itemHeight + Self.cellSpacing
        // Title field's own area above the grid (21pt font + its top
        // padding + the 28pt title-to-grid gap) and the scroll view's
        // bottom inset.
        let height = min(CGFloat(rows) * cellHeight + 88 + 70, 480)
        preferredContentSize = NSSize(width: panelWidth, height: max(height, 180))
    }

    private func refresh() {
        titleField.stringValue = model.folders[folderID]?.name ?? "Folder"
        flattenedItems = []
        if let folder = model.folders[folderID] {
            for (pageIndex, page) in folder.pages.enumerated() {
                for (itemIndex, item) in page.enumerated() {
                    flattenedItems.append((pageIndex, itemIndex, item))
                }
            }
        }
        updatePreferredContentSize()

        refreshGeneration += 1
        let generation = refreshGeneration
        let cache = iconCache

        var tiles: [FolderOverlayTile] = []
        for entry in flattenedItems {
            guard case .app(let id) = entry.item, let record = model.record(for: id) else { continue }
            let tileID = record.iconCacheKey
            let cachedIcon = cache.cachedIconIfAvailable(for: record)
            tiles.append(FolderOverlayTile(
                id: tileID,
                name: model.displayName(for: record),
                icon: cachedIcon,
                onLaunch: { [weak self] in self?.onLaunch(record) },
                onOpenNewInstance: record.canOpenNewInstance ? { [weak self] in
                    self?.model.recordLaunch(for: record.id)
                    Task { await self?.model.save() }
                    AppLauncher.launch(record, createsNewInstance: true)
                } : nil,
                onShowInFinder: { NSWorkspace.shared.activateFileViewerSelecting([record.bundleURL]) },
                onRemoveFromFolder: { [weak self] in
                    guard let self else { return }
                    self.onItemDraggedOut(entry.page, entry.index)
                    self.refresh()
                }
            ))
            if cachedIcon == nil {
                Task { @MainActor [weak self] in
                    let icon = await cache.icon(for: record)
                    guard let self, self.refreshGeneration == generation else { return }
                    guard let index = self.gridModel.tiles.firstIndex(where: { $0.id == tileID }) else { return }
                    self.gridModel.tiles[index].icon = icon
                    // Real, confirmed bug: a fresh folder open has every icon
                    // start nil and trickle in one at a time as each
                    // `cache.icon(for:)` await resolves — each of these
                    // `@Published` writes re-renders `FolderOverlayGridContent`,
                    // and one debug-hook check (which happened to sample
                    // only twice, at 0ms and +300ms) missed that a mid-stream
                    // re-render can race Auto Layout's width-constraint
                    // resolution and leave `NSHostingView` measured against
                    // its own narrower SwiftUI-computed intrinsic size
                    // instead of the imposed `scrollView.contentView.widthAnchor`
                    // — exactly the collapsed-column symptom, just
                    // intermittent depending on how many icons are still
                    // loading when a screenshot is taken. Forcing a
                    // synchronous layout pass after every trickle update
                    // makes the correct width win deterministically instead
                    // of depending on AppKit "eventually" reconciling it.
                    self.view.window?.layoutIfNeeded()
                }
            }
        }
        gridModel.tiles = tiles
        view.window?.layoutIfNeeded()
    }
}
