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
    private static let contentSize = NSSize(width: 320, height: 320)

    /// Flattened (folderPage, folderIndex, item) so context-menu "Remove from
    /// Folder" can address the exact underlying position.
    private var flattenedItems: [(page: Int, index: Int, item: LayoutItem)] = []

    init(
        model: GridModel,
        folderID: FolderID,
        iconCache: IconCache,
        onLaunch: @escaping (ApplicationRecord) -> Void,
        onItemDraggedOut: @escaping (Int, Int) -> Void
    ) {
        self.model = model
        self.folderID = folderID
        self.iconCache = iconCache
        self.onLaunch = onLaunch
        self.onItemDraggedOut = onItemDraggedOut
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func loadView() {
        let root = NSView()

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.alignment = .center

        let layout = NSCollectionViewFlowLayout()
        // Icon-only cells (no name label — see `configureAsApp`'s
        // `showsLabel: false` below): a compact grid reading like real
        // iOS/macOS Springboard folder contents, with the folder's own name
        // shown once above via `titleField` instead of repeated per-cell.
        layout.itemSize = NSSize(width: 64, height: 64)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

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

        root.addSubview(titleField)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.contentSize.width),
            root.heightAnchor.constraint(equalToConstant: Self.contentSize.height),

            titleField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            titleField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
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
        // *does* work for an Auto Layout view controller; the explicit
        // width/height constraints above back it so the layout is
        // unambiguous either way.
        preferredContentSize = Self.contentSize
        refresh()
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
            // Fixed, smaller than the main grid's iconSize: the folder
            // popover's cells are a compact 80x96pt, independent of the
            // user's main-grid icon size setting.
            let folderIconSize = 56.0
            cell.configureAsApp(record: record, icon: NSImage(), isSelected: false, iconSize: folderIconSize, showsLabel: false)
            let expectedKey = record.iconCacheKey
            Task { @MainActor in
                let icon = await cache.icon(for: record)
                // Same cell-reuse guard as GridViewController — see its comment.
                guard cell.currentRequestKey == expectedKey else { return }
                cell.configureAsApp(record: record, icon: icon, isSelected: false, iconSize: folderIconSize, showsLabel: false)
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
            showWindows: nil // Folder-internal items don't get the window browser shortcut yet; open the app itself first.
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
