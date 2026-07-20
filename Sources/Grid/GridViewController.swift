import AppKit
import Catalog
import Diagnostics
import Persistence

private struct DragPayload: Codable {
    var page: Int
    var index: Int
}

/// The persistent, folder-aware paged grid (2.2/2.4/2.7): backed by
/// `GridModel`+`PagedGridLayout`, with in-page reorder, cross-page drag,
/// folder creation/join/dissolve via drag, and a per-item context menu.
/// This is what `LauncherViewController` shows when there's no active search
/// query; search results still use the flat list from Phase 3.
public final class GridViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private static let internalDragType = NSPasteboard.PasteboardType("com.launchpadnative.griditem")
    private let itemIdentifier = NSUserInterfaceItemIdentifier("GridCellItem")

    private let model: GridModel
    private let iconCache: IconCache
    private let onLaunch: (ApplicationRecord) -> Void

    private let collectionView = GridCollectionView()
    private let scrollView = NSScrollView()
    private let pageControl = PageControlView()
    private let layout = PagedGridLayout()

    private var currentPage = 0
    private var openFolderPopover: NSPopover?

    public init(model: GridModel, iconCache: IconCache, onLaunch: @escaping (ApplicationRecord) -> Void) {
        self.model = model
        self.iconCache = iconCache
        self.onLaunch = onLaunch
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    public override func loadView() {
        let root = NSView()

        layout.settings = model.gridSettings
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(GridCellItem.self, forItemWithIdentifier: itemIdentifier)
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.setDraggingSourceOperationMask(.every, forLocal: false)
        collectionView.registerForDraggedTypes([Self.internalDragType])
        collectionView.menuProvider = { [weak self] indexPath in self?.contextMenu(for: indexPath) }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed

        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.onSelectPage = { [weak self] index in self?.jumpToPage(index) }

        root.addSubview(scrollView)
        root.addSubview(pageControl)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: pageControl.topAnchor, constant: -8),

            pageControl.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            pageControl.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            pageControl.heightAnchor.constraint(equalToConstant: 16)
        ])

        view = root
        model.onChange = { [weak self] in self?.reload() }
    }

    public func reload() {
        layout.settings = model.gridSettings
        collectionView.reloadData()
        pageControl.numberOfPages = model.pages.count
        pageControl.currentPage = currentPage
    }

    // MARK: Keyboard navigation (forwarded from LauncherViewController)

    public func moveSelection(deltaColumns: Int, deltaRows: Int) {
        guard let current = collectionView.selectionIndexPaths.first else {
            select(IndexPath(item: 0, section: 0))
            return
        }
        let columns = max(model.gridSettings.columns, 1)
        var flat = current.item + deltaColumns + deltaRows * columns
        var section = current.section
        let count = model.pages.indices.contains(section) ? model.pages[section].count : 0

        if flat < 0 {
            guard section > 0 else { return }
            section -= 1
            flat = max(model.pages[section].count - 1, 0)
        } else if flat >= count {
            guard section < model.pages.count - 1 else { return }
            section += 1
            flat = 0
        }
        select(IndexPath(item: flat, section: section))
        jumpToPage(section)
    }

    public func launchSelection() {
        guard let indexPath = collectionView.selectionIndexPaths.first else { return }
        activate(at: indexPath)
    }

    private func select(_ indexPath: IndexPath) {
        guard model.pages.indices.contains(indexPath.section),
              model.pages[indexPath.section].indices.contains(indexPath.item) else { return }
        collectionView.selectionIndexPaths = [indexPath]
        collectionView.reloadItems(at: [indexPath])
    }

    private func jumpToPage(_ index: Int) {
        guard model.pages.indices.contains(index) else { return }
        currentPage = index
        pageControl.currentPage = index
        scrollView.contentView.animator().setBoundsOrigin(layout.originForPage(index))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func activate(at indexPath: IndexPath) {
        guard model.pages.indices.contains(indexPath.section),
              model.pages[indexPath.section].indices.contains(indexPath.item) else { return }
        let item = model.pages[indexPath.section][indexPath.item]
        switch item {
        case .app(let id):
            guard let record = model.record(for: id) else { return }
            onLaunch(record)
        case .folder(let folderID):
            openFolder(folderID, anchorIndexPath: indexPath)
        }
    }

    private func openFolder(_ folderID: FolderID, anchorIndexPath: IndexPath) {
        guard let folder = model.folders[folderID],
              let cell = collectionView.item(at: anchorIndexPath) else { return }

        let folderVC = FolderContentsViewController(
            model: model,
            folderID: folderID,
            iconCache: iconCache,
            onLaunch: { [weak self] record in
                self?.openFolderPopover?.close()
                self?.onLaunch(record)
            },
            onItemDraggedOut: { [weak self] folderPage, folderIndex in
                self?.model.removeFromFolder(folderID, folderPage: folderPage, folderIndex: folderIndex, toPage: self?.currentPage ?? 0)
                Task { await self?.model.save() }
            }
        )
        let popover = NSPopover()
        popover.contentViewController = folderVC
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 320)
        popover.delegate = folderVC
        openFolderPopover = popover
        _ = folder // silence unused-in-release warnings if folder gains more fields later
        popover.show(relativeTo: cell.view.bounds, of: cell.view, preferredEdge: .maxY)
    }

    private func contextMenu(for indexPath: IndexPath) -> NSMenu? {
        guard model.pages.indices.contains(indexPath.section),
              model.pages[indexPath.section].indices.contains(indexPath.item) else { return nil }
        let item = model.pages[indexPath.section][indexPath.item]

        switch item {
        case .folder:
            return ContextMenuBuilder.folderMenu(rename: { [weak self] in
                self?.promptRenameFolder(at: indexPath)
            })
        case .app(let id):
            guard let record = model.record(for: id) else { return nil }
            let actions = ContextMenuBuilder.Actions(
                open: { [weak self] in self?.onLaunch(record) },
                openNewInstance: record.canOpenNewInstance ? { AppLauncher.launch(record, createsNewInstance: true) } : nil,
                showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([record.bundleURL]) },
                addToDock: {
                    DiagnosticsLog.launcher.info("Add to Dock requested for \(record.bundleIdentifier, privacy: .public); drag the icon onto the real Dock to complete this (see GridCollectionView pasteboard writer).")
                },
                rename: { [weak self] in self?.promptRenameApp(at: indexPath, record: record) },
                hide: { [weak self] in self?.hideApp(record) },
                removeFromFolder: nil,
                getInfo: { NSWorkspace.shared.activateFileViewerSelecting([record.bundleURL]) }
            )
            return ContextMenuBuilder.menu(for: record, isInFolder: false, actions: actions)
        }
    }

    private func promptRenameFolder(at indexPath: IndexPath) {
        guard case .folder(let folderID) = model.pages[indexPath.section][indexPath.item],
              let folder = model.folders[folderID] else { return }
        presentRenameAlert(currentName: folder.name) { [weak self] newName in
            self?.model.renameFolder(folderID, to: newName)
            Task { await self?.model.save() }
        }
    }

    private func promptRenameApp(at indexPath: IndexPath, record: ApplicationRecord) {
        // Display-name aliasing is Phase 6 (LayoutDocument.aliases); the
        // prompt exists now so the context menu's shape doesn't change later.
        presentRenameAlert(currentName: record.displayName) { _ in
            DiagnosticsLog.launcher.info("Alias rename UI captured; wiring to LayoutDocument.aliases lands in Phase 6")
        }
    }

    private func hideApp(_ record: ApplicationRecord) {
        // LayoutDocument.hiddenApplicationIDs write-back lands with the rest
        // of Phase 6's hide/unhide UI; logged for now so this isn't a silent
        // no-op menu item.
        DiagnosticsLog.launcher.info("Hide requested for \(record.bundleIdentifier, privacy: .public); persisted hide/unhide UI lands in Phase 6")
    }

    private func presentRenameAlert(currentName: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Rename"
        let field = NSTextField(string: currentName)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            completion(field.stringValue)
        }
    }

    // MARK: NSCollectionViewDataSource

    public func numberOfSections(in collectionView: NSCollectionView) -> Int {
        model.pages.count
    }

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        model.pages.indices.contains(section) ? model.pages[section].count : 0
    }

    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let cell = collectionView.makeItem(withIdentifier: itemIdentifier, for: indexPath) as? GridCellItem,
              model.pages.indices.contains(indexPath.section),
              model.pages[indexPath.section].indices.contains(indexPath.item) else {
            return NSCollectionViewItem()
        }
        let isSelected = collectionView.selectionIndexPaths.contains(indexPath)
        switch model.pages[indexPath.section][indexPath.item] {
        case .app(let id):
            guard let record = model.record(for: id) else { return cell }
            let cache = iconCache
            cell.configureAsApp(record: record, icon: NSImage(), isSelected: isSelected)
            Task { @MainActor in
                let icon = await cache.icon(for: record)
                cell.configureAsApp(record: record, icon: icon, isSelected: isSelected)
            }
        case .folder(let folderID):
            let folder = model.folders[folderID]
            let count = folder?.pages.reduce(0) { $0 + $1.count } ?? 0
            cell.configureAsFolder(name: folder?.name ?? "Folder", itemCount: count, isSelected: isSelected)
        }
        return cell
    }

    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        // Single click selects; a second click on an already-selected item
        // (or Enter) activates — matches Phase 3's search-list convention.
    }

    // MARK: Drag and drop
    //
    // Including `.fileURL` on the pasteboard item for `.app` cells is what
    // makes "drag onto the real Dock" (2.9) work for free: NSCollectionView's
    // built-in drag session already lets the OS hand this off to the Dock
    // process or Finder, no custom NSDraggingSource subclass required.

    public func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>) -> Bool {
        true
    }

    public func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard model.pages.indices.contains(indexPath.section),
              model.pages[indexPath.section].indices.contains(indexPath.item) else { return nil }
        let pbItem = NSPasteboardItem()
        if let payload = try? JSONEncoder().encode(DragPayload(page: indexPath.section, index: indexPath.item)) {
            pbItem.setData(payload, forType: Self.internalDragType)
        }
        if case .app(let id) = model.pages[indexPath.section][indexPath.item], let record = model.record(for: id) {
            pbItem.setString(record.bundleURL.absoluteString, forType: .fileURL)
        }
        return pbItem
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard draggingInfo.draggingPasteboard.availableType(from: [Self.internalDragType]) != nil else { return [] }
        return .move
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let data = draggingInfo.draggingPasteboard.data(forType: Self.internalDragType),
              let payload = try? JSONDecoder().decode(DragPayload.self, from: data) else { return false }

        if dropOperation == .on {
            model.createOrJoinFolder(
                sourcePage: payload.page,
                sourceIndex: payload.index,
                destinationPage: indexPath.section,
                destinationIndex: indexPath.item
            )
        } else {
            model.moveItem(
                fromPage: payload.page,
                fromIndex: payload.index,
                toPage: indexPath.section,
                toIndex: indexPath.item
            )
        }
        Task { await model.save() }
        return true
    }
}
