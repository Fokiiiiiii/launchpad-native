import AppKit
import Catalog
import Persistence

/// Shown in a transient `NSPopover` when a folder is opened. Folder-internal
/// paging (`Folder.pages`) is flattened to one scrollable list here — the
/// data model still tracks per-page ordering (needed for legacy import
/// fidelity), but a folder rarely holds enough items to need its own paging
/// UI, so this is a deliberate Phase 4 simplification, not a data loss.
final class FolderContentsViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSPopoverDelegate {
    private let itemIdentifier = NSUserInterfaceItemIdentifier("FolderCellItem")
    private let model: GridModel
    private let folderID: FolderID
    private let iconCache: IconCache
    private let onLaunch: (ApplicationRecord) -> Void
    private let onItemDraggedOut: (Int, Int) -> Void

    private let titleField = NSTextField(labelWithString: "")
    private let collectionView = GridCollectionView()
    private var pendingClickIndexPath: IndexPath?
    /// The main grid's own current icon size (`GridViewController.currentIconSize`)
    /// — a real design reference the user supplied directly asked for
    /// "内部アイコンが通常サイズの配置へ広がる" (contained icons expand to
    /// their normal size when the folder opens), which a fixed 56pt
    /// regardless of the grid's actual configured size did not satisfy.
    private let iconSize: Double
    /// Matches the "Tessera" design reference's `LazyVGrid(..., spacing: 26)`
    /// exactly — the previous 16pt was an invented value, not taken from
    /// the reference.
    private static let cellSpacing: CGFloat = 26
    private static let maxColumns = 7
    private var itemWidth: CGFloat { CGFloat(iconSize) + 24 }
    private var itemHeight: CGFloat { CGFloat(iconSize) + 40 }

    /// Flattened (folderPage, folderIndex, item) so context-menu "Remove from
    /// Folder" can address the exact underlying position.
    private var flattenedItems: [(page: Int, index: Int, item: LayoutItem)] = []

    init(
        model: GridModel,
        folderID: FolderID,
        iconCache: IconCache,
        iconSize: Double,
        onLaunch: @escaping (ApplicationRecord) -> Void,
        onItemDraggedOut: @escaping (Int, Int) -> Void
    ) {
        self.model = model
        self.folderID = folderID
        self.iconCache = iconCache
        self.iconSize = iconSize
        self.onLaunch = onLaunch
        self.onItemDraggedOut = onItemDraggedOut
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func loadView() {
        let root = NSView()

        // Dark, styled card background (Round 12 §3) — a decorative sibling
        // behind the title/collection view, matching the reference's
        // self-contained floating "Utilities"-style card rather than the
        // bare, unstyled default NSPopover chrome this used to rely on.
        // `NSPopover` itself is deliberately kept (not replaced with a
        // custom borderless NSWindow) since its `.transient` behavior
        // already gives correct "outside click closes just the popover,
        // never the launcher" dismissal for free — a thin sliver of the
        // popover's own default bezel/arrow remains around this card since
        // there's no public API to fully suppress it. Corner radius (34)
        // matches the "Tessera" design reference's own folder panel exactly
        // — a generous, simple rounded card, no extra dividers/section
        // headers beyond the title (matches the user's explicit
        // "シンプルな角丸パネル...上部にグループ名だけ" request).
        let background = GlassBackgroundHelper.makeBackground(cornerRadius: 34, dark: true)
        background.translatesAutoresizingMaskIntoConstraints = false

        titleField.translatesAutoresizingMaskIntoConstraints = false
        // 21pt regular weight — the reference's own
        // `Text(folder.name).font(.system(size: TSLayout.folderTitleSize))`
        // has no explicit weight (defaults to regular); the previous 15pt
        // semibold was an invented value, not taken from the reference.
        titleField.font = .systemFont(ofSize: 21, weight: .regular)
        titleField.alignment = .center

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: itemWidth, height: itemHeight)
        layout.minimumInteritemSpacing = Self.cellSpacing
        layout.minimumLineSpacing = Self.cellSpacing
        // Matches the reference's grid padding
        // (`.padding(.horizontal, 22).padding(.vertical, 34)`) exactly.
        layout.sectionInset = NSEdgeInsets(top: 34, left: 22, bottom: 34, right: 22)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(GridCellItem.self, forItemWithIdentifier: itemIdentifier)
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.menuProvider = { [weak self] indexPath in self?.contextMenu(for: indexPath) }
        // Real, confirmed bug: `GridCollectionView`'s `mouseDown` override
        // never calls `super.mouseDown(with:)` for a content hit (see that
        // class's doc comment) — it only calls `onItemMouseDown`, which this
        // controller never wired up. That silently broke clicking an app
        // inside an opened folder (no click ever reached
        // `didSelectItemsAt`), on top of `didSelectItemsAt` itself never
        // firing for the same reason. Wired here with the simplest
        // click-only handling this view needs — no drag/reorder/folder-
        // creation machinery, since a folder's contents are a flat list.
        collectionView.onItemMouseDown = { [weak self] indexPath, _ in
            self?.pendingClickIndexPath = indexPath
        }
        collectionView.onItemMouseUp = { [weak self] _ in
            guard let self, let indexPath = self.pendingClickIndexPath else { return }
            self.pendingClickIndexPath = nil
            self.collectionView(self.collectionView, didSelectItemsAt: [indexPath])
        }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
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
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
        view = root
        // Real, confirmed bug: `NSPopover.contentSize` (set by the caller in
        // `GridViewController.openFolder`) has no effect once the content
        // view controller's view uses Auto Layout (documented Apple
        // behavior) — this view has no explicit size constraints of its own
        // otherwise, so Auto Layout collapsed it to whatever minimum size
        // its children could shrink to, which is why the popover appeared
        // stuck at roughly the size of the folder icon itself instead of
        // actually opening. `preferredContentSize` is the mechanism that
        // *does* work for an Auto Layout view controller.
        refresh()
    }

    /// Computes `preferredContentSize` from the actual item count — a wide
    /// (up to 7 columns), scrollable card rather than the old fixed 320x320
    /// square, matching the reference's wide "Utilities"-style folder.
    private func updatePreferredContentSize() {
        let itemCount = max(flattenedItems.count, 1)
        let columns = max(1, min(Self.maxColumns, Int(ceil(sqrt(Double(itemCount) * 1.6)))))
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
        collectionView.reloadData()
    }

    // MARK: NSCollectionViewDataSource

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        flattenedItems.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let cell = collectionView.makeItem(withIdentifier: itemIdentifier, for: indexPath) as? GridCellItem,
              flattenedItems.indices.contains(indexPath.item) else {
            return NSCollectionViewItem()
        }
        let entry = flattenedItems[indexPath.item]
        if case .app(let id) = entry.item, let record = model.record(for: id) {
            let cache = iconCache
            cell.configureAsApp(record: record, icon: NSImage(), isSelected: false, iconSize: iconSize)
            let expectedKey = record.iconCacheKey
            Task { @MainActor in
                let icon = await cache.icon(for: record)
                // Same cell-reuse guard as GridViewController — see its comment.
                guard cell.currentRequestKey == expectedKey else { return }
                cell.configureAsApp(record: record, icon: icon, isSelected: false, iconSize: iconSize)
            }
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first, flattenedItems.indices.contains(indexPath.item) else { return }
        let entry = flattenedItems[indexPath.item]
        if case .app(let id) = entry.item, let record = model.record(for: id) {
            onLaunch(record)
        }
    }

    private func contextMenu(for indexPath: IndexPath) -> NSMenu? {
        guard flattenedItems.indices.contains(indexPath.item) else { return nil }
        let entry = flattenedItems[indexPath.item]
        guard case .app(let id) = entry.item, let record = model.record(for: id) else { return nil }

        let actions = ContextMenuBuilder.Actions(
            open: { [weak self] in self?.onLaunch(record) },
            openNewInstance: record.canOpenNewInstance ? { [weak self] in
                self?.model.recordLaunch(for: record.id)
                Task { await self?.model.save() }
                AppLauncher.launch(record, createsNewInstance: true)
            } : nil,
            showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([record.bundleURL]) },
            addToDock: {},
            rename: {},
            hide: {},
            removeFromFolder: { [weak self] in
                guard let self else { return }
                self.onItemDraggedOut(entry.page, entry.index)
                self.refresh()
            },
            getInfo: { NSWorkspace.shared.activateFileViewerSelecting([record.bundleURL]) },
            showWindows: nil, // Folder-internal items don't get the window browser shortcut yet; open the app itself first.
            uninstall: nil // Same reasoning as showWindows: open the app itself first.
        )
        return ContextMenuBuilder.menu(for: record, isInFolder: true, actions: actions)
    }

    // MARK: NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Nothing to persist here directly — GridModel mutations already
        // save themselves; this exists so future folder-specific cleanup
        // (e.g. auto-collapsing an emptied folder's popover) has a hook.
    }
}
