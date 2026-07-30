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
    /// Matches the "Tessera" design reference's `LazyVGrid(..., spacing: 26)`
    /// exactly — the previous 16pt was an invented value, not taken from
    /// the reference.
    private static let cellSpacing: CGFloat = 26
    private var itemWidth: CGFloat { CGFloat(iconSize) + 24 }
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
        onLaunch: @escaping (ApplicationRecord) -> Void,
        onItemDraggedOut: @escaping (Int, Int) -> Void
    ) {
        self.model = model
        self.folderID = folderID
        self.iconCache = iconCache
        self.iconSize = iconSize
        self.columns = max(columns, 1)
        self.onLaunch = onLaunch
        self.onItemDraggedOut = onItemDraggedOut
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func loadView() {
        let root = NSView()

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

        let hosting = NSHostingView(rootView: FolderOverlayGridContent(model: gridModel, columns: columns, iconSize: CGFloat(iconSize)))
        hosting.translatesAutoresizingMaskIntoConstraints = false

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

            scrollView.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            hosting.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: scrollView.topAnchor)
        ])
        view = root
        // `NSPopover.contentSize`/the caller's own size constraints have no
        // effect once the content view controller's view uses Auto Layout
        // (documented Apple behavior) — `preferredContentSize` is the
        // mechanism that actually works for an Auto Layout view controller.
        refresh()
    }

    /// Computes `preferredContentSize` from the fixed `columns` count (the
    /// main grid's own column count — see that property's doc comment for
    /// why this isn't a per-item-count heuristic) — width is therefore
    /// always the same regardless of how many apps the folder holds; only
    /// the row count (hence height, up to the 480pt/scrolling cap) grows
    /// or shrinks with the actual item count.
    private func updatePreferredContentSize() {
        let itemCount = max(flattenedItems.count, 1)
        let rows = max(1, Int(ceil(Double(itemCount) / Double(columns))))
        let cellWidth = itemWidth + Self.cellSpacing
        let cellHeight = itemHeight + Self.cellSpacing
        // Horizontal/vertical section inset (22/34, matching the reference)
        // plus the title field's own area above the grid (21pt font + its
        // top padding/gap constraints) and the scroll view's bottom inset.
        let width = min(CGFloat(columns) * cellWidth + 44, 640)
        let height = min(CGFloat(rows) * cellHeight + 68 + 70, 480)
        preferredContentSize = NSSize(width: max(width, 240), height: max(height, 180))
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
                }
            }
        }
        gridModel.tiles = tiles
    }
}
