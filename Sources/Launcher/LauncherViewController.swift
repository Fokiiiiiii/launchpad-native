import AppKit
import Catalog
import Diagnostics
import Grid
import Localization
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
    private let onOpenSettings: () -> Void
    private let onRequestUninstall: (String) -> Void

    private let searchField = NSTextField()
    private let searchIcon = NSImageView()
    private let settingsButton = NSButton()
    private let searchResultsCollectionView = SearchResultsCollectionView()
    private let searchResultsScrollView = NSScrollView()
    private let searchResultsLayout = NSCollectionViewFlowLayout()
    private let itemIdentifier = NSUserInterfaceItemIdentifier("AppIconItem")
    private lazy var gridViewController = GridViewController(
        model: gridModel,
        iconCache: iconCache,
        onLaunch: { [weak self] record in self?.launch(record) },
        onBackgroundClick: { [weak self] in self?.onDidCancel() },
        onRequestUninstall: { [weak self] bundleIdentifier in self?.onRequestUninstall(bundleIdentifier) }
    )

    init(
        viewModel: LauncherViewModel,
        gridModel: GridModel,
        iconCache: IconCache,
        onDidLaunch: @escaping () -> Void,
        onDidCancel: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onRequestUninstall: @escaping (String) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.gridModel = gridModel
        self.iconCache = iconCache
        self.onDidLaunch = onDidLaunch
        self.onDidCancel = onDidCancel
        self.onRequestUninstall = onRequestUninstall
        self.onOpenSettings = onOpenSettings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func loadView() {
        let root = BackgroundClickCatcherView()
        root.onBackgroundClick = { [weak self] in self?.onDidCancel() }

        // The search field reads as its own floating glass capsule (Spotlight's
        // own search field is a distinct material, not bare text on the
        // ambient background) — `searchBarGlass` is a purely decorative
        // sibling behind `searchIcon`/`searchField`, never their container,
        // for the same hit-testing reason `GlassBackgroundView`'s doc
        // comment explains for the full-screen background.
        let searchBarGlass = GlassBackgroundFactory.makeBackground(cornerRadius: 20)
        searchBarGlass.translatesAutoresizingMaskIntoConstraints = false

        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        searchIcon.contentTintColor = .secondaryLabelColor

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.cell = SearchFieldCell()
        searchField.placeholderAttributedString = NSAttributedString(
            string: L10n.searchPlaceholder,
            attributes: [.kern: -0.4, .foregroundColor: NSColor.placeholderTextColor]
        )
        searchField.font = .systemFont(ofSize: 20, weight: .regular)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.setAccessibilityLabel(L10n.searchAccessibilityLabel)

        // A small circular glass chip, same reasoning as the search
        // capsule above — decorative sibling, button drawn on top of it.
        let settingsGlass = GlassBackgroundFactory.makeBackground(cornerRadius: 14)
        settingsGlass.translatesAutoresizingMaskIntoConstraints = false

        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.bezelStyle = .circular
        settingsButton.isBordered = false
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L10n.settingsButtonAccessibilityLabel)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(settingsButtonTapped)

        applySearchResultsLayoutMetrics()

        searchResultsCollectionView.collectionViewLayout = searchResultsLayout
        searchResultsCollectionView.dataSource = self
        searchResultsCollectionView.delegate = self
        searchResultsCollectionView.register(AppIconCollectionViewItem.self, forItemWithIdentifier: itemIdentifier)
        searchResultsCollectionView.isSelectable = true
        searchResultsCollectionView.backgroundColors = [.clear]
        searchResultsCollectionView.onBackgroundClick = { [weak self] in self?.onDidCancel() }

        searchResultsScrollView.translatesAutoresizingMaskIntoConstraints = false
        searchResultsScrollView.documentView = searchResultsCollectionView
        searchResultsScrollView.drawsBackground = false
        searchResultsScrollView.hasVerticalScroller = true
        searchResultsScrollView.isHidden = true

        addChild(gridViewController)
        gridViewController.view.translatesAutoresizingMaskIntoConstraints = false

        // Plain positioning containers (not glass themselves) — each holds
        // one glass shape plus the real interactive control(s) as siblings
        // drawn on top of it, so the capsule/chip reads as one floating
        // piece of glass while every click still hits a normal AppKit
        // control directly.
        let searchBar = NSView()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(searchBarGlass)
        searchBar.addSubview(searchIcon)
        searchBar.addSubview(searchField)

        let settingsChip = NSView()
        settingsChip.translatesAutoresizingMaskIntoConstraints = false
        settingsChip.addSubview(settingsGlass)
        settingsChip.addSubview(settingsButton)

        root.addSubview(searchBar)
        root.addSubview(settingsChip)
        root.addSubview(gridViewController.view)
        root.addSubview(searchResultsScrollView)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            searchBar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            searchBar.widthAnchor.constraint(equalToConstant: 400),
            searchBar.heightAnchor.constraint(equalToConstant: 44),

            searchBarGlass.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor),
            searchBarGlass.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor),
            searchBarGlass.topAnchor.constraint(equalTo: searchBar.topAnchor),
            searchBarGlass.bottomAnchor.constraint(equalTo: searchBar.bottomAnchor),

            searchIcon.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -16),
            searchField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),

            settingsChip.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            settingsChip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            settingsChip.widthAnchor.constraint(equalToConstant: 32),
            settingsChip.heightAnchor.constraint(equalToConstant: 32),

            settingsGlass.leadingAnchor.constraint(equalTo: settingsChip.leadingAnchor),
            settingsGlass.trailingAnchor.constraint(equalTo: settingsChip.trailingAnchor),
            settingsGlass.topAnchor.constraint(equalTo: settingsChip.topAnchor),
            settingsGlass.bottomAnchor.constraint(equalTo: settingsChip.bottomAnchor),

            settingsButton.centerXAnchor.constraint(equalTo: settingsChip.centerXAnchor),
            settingsButton.centerYAnchor.constraint(equalTo: settingsChip.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 28),
            settingsButton.heightAnchor.constraint(equalToConstant: 28),

            gridViewController.view.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 24),
            gridViewController.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            gridViewController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            gridViewController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            searchResultsScrollView.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 24),
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
        applySearchResultsLayoutMetrics()
        view.window?.makeFirstResponder(searchField)
    }

    func resetSearch() {
        searchField.stringValue = ""
        viewModel.setQuery("")
        setSearchMode(active: false)
        // Safety net for the page-drag machinery: every time the launcher
        // shows, force a clean state regardless of how the previous
        // session ended — see `GridViewController.resetDragStateIfNeeded`'s
        // doc comment for why this exists (a lesson from a prior version
        // of this feature that could get stuck).
        gridViewController.resetDragStateIfNeeded()
    }

    /// Debug-only entry point (`LAUNCHPAD_DEBUG_SEARCH_QUERY`, wired in
    /// `AppDelegate`) so the search-results layout can actually be driven
    /// and screenshotted without Accessibility/GUI-scripting permission to
    /// type into the field interactively — see `AppDelegate`'s doc comment
    /// on the env var for why this exists.
    func debugSetSearchQuery(_ query: String) {
        searchField.stringValue = query
        applyQuery(query)
    }

    func reloadGrid() {
        gridViewController.reload()
        applySearchResultsLayoutMetrics()
    }

    /// Debug-only entry point (`LAUNCHPAD_DEBUG_SIMULATE_PAGE_DRAG`, wired
    /// in `AppDelegate`) — see `GridViewController.debugSimulatePageDrag`'s
    /// doc comment for why this exists.
    func debugSimulatePageDrag(commit: Bool) {
        gridViewController.debugSimulatePageDrag(commit: commit)
    }

    /// Search results previously used their own hardcoded cell size,
    /// spacing, and margins entirely independent of the persistent grid —
    /// two related user reports ("検索欄に文字を入れるとアプリのサイズが
    /// 壊れる", then "レイアウトも合わない" once icon size alone was fixed):
    /// typing a query didn't just change icon size, it swapped in a
    /// visually different grid (different column count, gaps, edges). Both
    /// views share one full-width surface, so reusing the grid's actual
    /// per-cell size (`GridViewController.currentCellSize`) and its real
    /// spacing/margins from `GridSettings` — instead of independently-tuned
    /// constants — makes the flat search list line up as the *same* grid,
    /// just filtered, rather than a different one.
    private func applySearchResultsLayoutMetrics() {
        let cellSize = gridViewController.currentCellSize
        let settings = gridModel.gridSettings
        let itemSize = cellSize.width > 0 && cellSize.height > 0
            ? cellSize
            : NSSize(width: 96, height: 110) // before the grid's first layout pass
        let margin = CGFloat(settings.pageMargins)
        let insets = NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)

        let currentInset = searchResultsLayout.sectionInset
        let insetsUnchanged = currentInset.top == insets.top && currentInset.left == insets.left
            && currentInset.bottom == insets.bottom && currentInset.right == insets.right
        guard searchResultsLayout.itemSize != itemSize
            || searchResultsLayout.minimumInteritemSpacing != CGFloat(settings.horizontalSpacing)
            || searchResultsLayout.minimumLineSpacing != CGFloat(settings.verticalSpacing)
            || !insetsUnchanged else { return }

        searchResultsLayout.itemSize = itemSize
        searchResultsLayout.minimumInteritemSpacing = CGFloat(settings.horizontalSpacing)
        searchResultsLayout.minimumLineSpacing = CGFloat(settings.verticalSpacing)
        searchResultsLayout.sectionInset = insets
        searchResultsLayout.invalidateLayout()
    }

    @objc private func settingsButtonTapped() {
        onOpenSettings()
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

    /// Large display text wants slightly negative tracking (Apple's own
    /// type-detail guidance — at 20pt, zero/positive tracking reads too
    /// loose). `NSTextField` has no direct kerning property for live-typed
    /// text; the field editor's `typingAttributes` is the actual hook.
    func controlTextDidBeginEditing(_ obj: Notification) {
        if let fieldEditor = obj.userInfo?["NSFieldEditor"] as? NSTextView {
            fieldEditor.typingAttributes[.kern] = -0.4
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applyQuery(searchField.stringValue)
    }

    private func applyQuery(_ query: String) {
        viewModel.setQuery(query)
        applySearchResultsLayoutMetrics()
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
        let iconSize = gridViewController.currentIconSize
        item.configure(record: record, icon: NSWorkspace.shared.icon(for: .applicationBundle), isSelected: isSelected, iconSize: iconSize)

        let cache = iconCache
        let expectedKey = record.iconCacheKey
        Task { @MainActor in
            let icon = await cache.icon(for: record)
            // Search results reload on every keystroke, recycling cells —
            // same cell-reuse guard as Grid.GridCellItem, see its comment.
            guard item.currentRequestKey == expectedKey else { return }
            item.configure(record: record, icon: icon, isSelected: isSelected, iconSize: iconSize)
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
