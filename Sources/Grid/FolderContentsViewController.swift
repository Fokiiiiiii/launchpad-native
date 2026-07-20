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
        layout.itemSize = NSSize(width: 80, height: 96)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(GridCellItem.self, forItemWithIdentifier: itemIdentifier)
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.menuProvider = { [weak self] indexPath in self?.contextMenu(for: indexPath) }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        root.addSubview(titleField)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            titleField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
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
            cell.configureAsApp(record: record, icon: NSImage(), isSelected: false)
            Task { @MainActor in
                let icon = await cache.icon(for: record)
                cell.configureAsApp(record: record, icon: icon, isSelected: false)
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
            openNewInstance: record.canOpenNewInstance ? { AppLauncher.launch(record, createsNewInstance: true) } : nil,
            showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([record.bundleURL]) },
            addToDock: {},
            rename: {},
            hide: {},
            removeFromFolder: { [weak self] in
                guard let self else { return }
                self.onItemDraggedOut(entry.page, entry.index)
                self.refresh()
            },
            getInfo: { NSWorkspace.shared.activateFileViewerSelecting([record.bundleURL]) }
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
