import AppKit
import Catalog
import Diagnostics
import Grid
import UniformTypeIdentifiers

/// Two display modes sharing one search field: an empty query shows
/// `GridViewController` (the persistent, folder-aware, custom-layout paged
/// grid from Phase 4); typing a query switches to a flat, flattened search
/// results list (folders don't nest in search — matches Launchpad/Spotlight
/// convention of flattening structure once you start typing).
final class LauncherViewController: NSViewController, NSTextFieldDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let viewModel: LauncherViewModel
    private let gridModel: GridModel
    private let iconCache: IconCache
    private let onDidLaunch: () -> Void
    private let onDidCancel: () -> Void

    private let searchField = NSTextField()
    private let searchResultsCollectionView = NSCollectionView()
    private let searchResultsScrollView = NSScrollView()
    private let itemIdentifier = NSUserInterfaceItemIdentifier("AppIconItem")
    private lazy var gridViewController = GridViewController(
        model: gridModel,
        iconCache: iconCache,
        onLaunch: { [weak self] record in self?.launch(record) },
        onBackgroundClick: { [weak self] in self?.onDidCancel() }
    )

    init(
        viewModel: LauncherViewModel,
        gridModel: GridModel,
        iconCache: IconCache,
        onDidLaunch: @escaping () -> Void,
        onDidCancel: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.gridModel = gridModel
        self.iconCache = iconCache
        self.onDidLaunch = onDidLaunch
        self.onDidCancel = onDidCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func loadView() {
        let root = BackgroundClickCatcherView()
        root.onBackgroundClick = { [weak self] in self?.onDidCancel() }

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search"
        searchField.font = .systemFont(ofSize: 20, weight: .regular)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 96, height: 110)
        layout.minimumInteritemSpacing = 24
        layout.minimumLineSpacing = 24
        layout.sectionInset = NSEdgeInsets(top: 24, left: 48, bottom: 24, right: 48)

        searchResultsCollectionView.collectionViewLayout = layout
        searchResultsCollectionView.dataSource = self
        searchResultsCollectionView.delegate = self
        searchResultsCollectionView.register(AppIconCollectionViewItem.self, forItemWithIdentifier: itemIdentifier)
        searchResultsCollectionView.isSelectable = true
        searchResultsCollectionView.backgroundColors = [.clear]

        searchResultsScrollView.translatesAutoresizingMaskIntoConstraints = false
        searchResultsScrollView.documentView = searchResultsCollectionView
        searchResultsScrollView.drawsBackground = false
        searchResultsScrollView.hasVerticalScroller = true
        searchResultsScrollView.isHidden = true

        addChild(gridViewController)
        gridViewController.view.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(gridViewController.view)
        root.addSubview(searchResultsScrollView)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            searchField.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 360),

            gridViewController.view.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 24),
            gridViewController.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            gridViewController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            gridViewController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            searchResultsScrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 24),
            searchResultsScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchResultsScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchResultsScrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        viewModel.onChange = { [weak self] in
            self?.searchResultsCollectionView.reloadData()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    func resetSearch() {
        searchField.stringValue = ""
        viewModel.setQuery("")
        setSearchMode(active: false)
    }

    func reloadGrid() {
        gridViewController.reload()
    }

    private func setSearchMode(active: Bool) {
        searchResultsScrollView.isHidden = !active
        gridViewController.view.isHidden = active
    }

    private func launch(_ record: ApplicationRecord) {
        AppLauncher.launch(record) { [weak self] in
            self?.onDidLaunch()
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue
        viewModel.setQuery(query)
        setSearchMode(active: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let inSearchMode = !searchResultsScrollView.isHidden
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if inSearchMode {
                viewModel.moveSelection(by: 7) // one grid row, matches default column count until Phase 6 grid settings wire in
            } else {
                gridViewController.moveSelection(deltaColumns: 0, deltaRows: 1)
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if inSearchMode {
                viewModel.moveSelection(by: -7)
            } else {
                gridViewController.moveSelection(deltaColumns: 0, deltaRows: -1)
            }
            return true
        case #selector(NSResponder.moveLeft(_:)):
            if inSearchMode {
                viewModel.moveSelection(by: -1)
            } else {
                gridViewController.moveSelection(deltaColumns: -1, deltaRows: 0)
            }
            return true
        case #selector(NSResponder.moveRight(_:)):
            if inSearchMode {
                viewModel.moveSelection(by: 1)
            } else {
                gridViewController.moveSelection(deltaColumns: 1, deltaRows: 0)
            }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if inSearchMode {
                launchSearchSelection()
            } else {
                gridViewController.launchSelection()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDidCancel()
            return true
        default:
            return false
        }
    }

    private func launchSearchSelection() {
        guard let record = viewModel.selectedRecord else { return }
        launch(record)
    }

    // MARK: NSCollectionViewDataSource (search results only)

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        viewModel.filteredRecords.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let item = collectionView.makeItem(withIdentifier: itemIdentifier, for: indexPath) as? AppIconCollectionViewItem else {
            return NSCollectionViewItem()
        }
        let record = viewModel.filteredRecords[indexPath.item]
        let isSelected = viewModel.selectedIndex == indexPath.item
        item.configure(record: record, icon: NSWorkspace.shared.icon(for: .applicationBundle), isSelected: isSelected)

        let cache = iconCache
        Task { @MainActor in
            let icon = await cache.icon(for: record)
            item.configure(record: record, icon: icon, isSelected: isSelected)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item else { return }
        if index == viewModel.selectedIndex {
            launchSearchSelection()
        } else {
            viewModel.select(index: index)
        }
    }
}
