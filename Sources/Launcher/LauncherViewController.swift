import AppKit
import Catalog
import Diagnostics
import UniformTypeIdentifiers

/// Phase 3 content: search field + a plain `NSCollectionViewFlowLayout` grid.
/// The custom paged/vertical `NSCollectionViewLayout` (pages, folders,
/// cross-page drag) is Phase 4 — this exists to prove the launcher surface,
/// search, keyboard nav, and launch path work end-to-end first.
final class LauncherViewController: NSViewController, NSTextFieldDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let viewModel: LauncherViewModel
    private let iconCache: IconCache
    private let onDidLaunch: () -> Void
    private let onDidCancel: () -> Void

    private let searchField = NSTextField()
    private let collectionView = NSCollectionView()
    private let scrollView = NSScrollView()
    private let itemIdentifier = NSUserInterfaceItemIdentifier("AppIconItem")

    init(viewModel: LauncherViewModel, iconCache: IconCache, onDidLaunch: @escaping () -> Void, onDidCancel: @escaping () -> Void) {
        self.viewModel = viewModel
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

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(AppIconCollectionViewItem.self, forItemWithIdentifier: itemIdentifier)
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        root.addSubview(searchField)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            searchField.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 360),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 24),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        viewModel.onChange = { [weak self] in
            self?.collectionView.reloadData()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    func resetSearch() {
        searchField.stringValue = ""
        viewModel.setQuery("")
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        viewModel.setQuery(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            viewModel.moveSelection(by: 7) // one grid row, matches default column count until Phase 4/6 grid settings wire in
            return true
        case #selector(NSResponder.moveUp(_:)):
            viewModel.moveSelection(by: -7)
            return true
        case #selector(NSResponder.moveLeft(_:)):
            viewModel.moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveRight(_:)):
            viewModel.moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            launchSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDidCancel()
            return true
        default:
            return false
        }
    }

    private func launchSelection() {
        guard let record = viewModel.selectedRecord else { return }
        AppLauncher.launch(record) { [weak self] in
            self?.onDidLaunch()
        }
    }

    // MARK: NSCollectionViewDataSource

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
            launchSelection()
        } else {
            viewModel.select(index: index)
        }
    }
}
