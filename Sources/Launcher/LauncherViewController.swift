import AppKit
import Catalog
import Diagnostics
import Grid
import Localization
import Persistence
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
    private let quickMenuButton = NSButton()
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
        self.onOpenSettings = onOpenSettings
        self.onRequestUninstall = onRequestUninstall
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
        // Real, confirmed root cause of "clicking the search field closes
        // the launcher": a bare `NSTextFieldCell()` (what `SearchFieldCell()`
        // constructs) defaults to *not* editable/selectable — unlike
        // `NSTextField`'s own convenience initializers, which configure
        // their default cell that way for you. Assigning a fresh custom
        // cell via `.cell = ...` does not inherit that configuration, so
        // without these two lines the cell silently declined every mouse
        // click (not editable → nothing to track), and `NSControl.mouseDown`
        // fell back to `super.mouseDown(event)`, which walks the responder
        // chain up through this field's superviews and ultimately reached
        // `BackgroundClickCatcherView.mouseDown` — indistinguishable from a
        // real background click, so it closed the launcher. Confirmed via a
        // debug hook that called `mouseDown(with:)` directly on the exact
        // view `hitTest` had already identified as the search field: even
        // that direct call still propagated to the background catcher,
        // which only makes sense as a responder-chain fallback, not a
        // hit-testing problem — hitTest was correctly resolving to this
        // field the entire time.
        searchField.isEditable = true
        searchField.isSelectable = true
        // Same bug family as isEditable/isSelectable above: a bare
        // `NSTextFieldCell()` also doesn't inherit `NSTextField`'s
        // convenience-init defaults for single-line layout. Without these,
        // the cell treated its content as multi-line-capable, which — even
        // for a short single-line placeholder — top-anchors the text within
        // the cell's bounds instead of true single-line vertical centering,
        // explaining why the placeholder/typed text sat visibly higher than
        // the search icon next to it (both are centerY-anchored to the same
        // pill, so the icon's correct centering exposed the text's offset).
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.lineBreakMode = .byTruncatingTail
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

        // Real, confirmed duplication the user called out ("設定ボタンへの
        // 経路は二つある"): this used to be a second, permanently-visible
        // glass chip with its own gearshape button living right next to
        // the quick-menu chip below — both routes opened the exact same
        // Settings window. Removed in favor of a single entry point (the
        // quick menu's "Open Settings…" item, wired up below), matching
        // the reference design's search bar (one "•••" chip, no separate
        // persistent gear icon).
        //
        // A single glass chip for a quick-access menu (browsing mode, sort
        // order, and a Settings shortcut) without requiring a full trip
        // into Settings for a toggle already surfaced there.
        let quickMenuGlass = GlassBackgroundFactory.makeBackground(cornerRadius: 14)
        quickMenuGlass.translatesAutoresizingMaskIntoConstraints = false

        quickMenuButton.translatesAutoresizingMaskIntoConstraints = false
        quickMenuButton.bezelStyle = .circular
        quickMenuButton.isBordered = false
        quickMenuButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: L10n.quickMenuAccessibilityLabel)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        quickMenuButton.contentTintColor = .secondaryLabelColor
        quickMenuButton.target = self
        quickMenuButton.action = #selector(quickMenuButtonTapped)

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

        let quickMenuChip = NSView()
        quickMenuChip.translatesAutoresizingMaskIntoConstraints = false
        quickMenuChip.addSubview(quickMenuGlass)
        quickMenuChip.addSubview(quickMenuButton)

        root.addSubview(searchBar)
        root.addSubview(quickMenuChip)
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
            // SF Symbol "magnifyingglass" has its handle in the lower-right,
            // so its optical center sits slightly up-left of the glyph's
            // true geometric center — nudge centerY up by 1pt to compensate.
            searchIcon.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor, constant: -1),
            searchIcon.widthAnchor.constraint(equalToConstant: 20),
            searchIcon.heightAnchor.constraint(equalToConstant: 20),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -16),
            searchField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),

            quickMenuChip.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            quickMenuChip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            quickMenuChip.widthAnchor.constraint(equalToConstant: 32),
            quickMenuChip.heightAnchor.constraint(equalToConstant: 32),

            quickMenuGlass.leadingAnchor.constraint(equalTo: quickMenuChip.leadingAnchor),
            quickMenuGlass.trailingAnchor.constraint(equalTo: quickMenuChip.trailingAnchor),
            quickMenuGlass.topAnchor.constraint(equalTo: quickMenuChip.topAnchor),
            quickMenuGlass.bottomAnchor.constraint(equalTo: quickMenuChip.bottomAnchor),

            quickMenuButton.centerXAnchor.constraint(equalTo: quickMenuChip.centerXAnchor),
            quickMenuButton.centerYAnchor.constraint(equalTo: quickMenuChip.centerYAnchor),
            quickMenuButton.widthAnchor.constraint(equalToConstant: 28),
            quickMenuButton.heightAnchor.constraint(equalToConstant: 28),

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
        DiagnosticsLog.launcher.info("viewDidAppear layout: root=\(String(describing: self.view.frame), privacy: .public), grid=\(String(describing: self.gridViewController.view.frame), privacy: .public), searchField=\(String(describing: self.searchField.convert(self.searchField.bounds, to: self.view)), privacy: .public)")
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

    /// Debug-only entry point (`LAUNCHPAD_DEBUG_CLICK_SEARCH_FIELD`, wired
    /// in `AppDelegate`) — synthesizes a *real* `NSEvent` mouse down/up pair
    /// at the search field's actual on-screen location and dispatches it
    /// through `window.sendEvent(_:)`, so the exact hit-testing/responder
    /// path a real trackpad click takes can be exercised and logged without
    /// Accessibility/GUI-scripting permission to perform one. Exists
    /// specifically because a prior fix (making the decorative glass
    /// background's `hitTest` always return `nil`) didn't resolve a real
    /// user report that clicking the search field still closes the
    /// launcher — this lets that exact path be re-examined via `log
    /// stream` without needing the user's own hands-on retest for every
    /// iteration.
    func debugSimulateSearchFieldClick() {
        guard let window = view.window else {
            DiagnosticsLog.launcher.info("debugSimulateSearchFieldClick: no window")
            return
        }
        let frameInWindow = searchField.convert(searchField.bounds, to: nil)
        let point = NSPoint(x: frameInWindow.midX, y: frameInWindow.midY)
        DiagnosticsLog.launcher.info("debugSimulateSearchFieldClick: dispatching at \(String(describing: point), privacy: .public), frameInWindow=\(String(describing: frameInWindow), privacy: .public)")

        // Direct hitTest probes (bypassing sendEvent entirely) to pin down
        // exactly which level of the hierarchy actually claims this point.
        let contentViewHit = window.contentView?.hitTest(point)
        let selfViewHit = view.hitTest(view.convert(point, from: nil))
        DiagnosticsLog.launcher.info("debugSimulateSearchFieldClick: window.contentView.hitTest -> \(String(describing: contentViewHit), privacy: .public), self.view.hitTest -> \(String(describing: selfViewHit), privacy: .public), searchField itself is \(String(describing: self.searchField), privacy: .public)")

        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ), let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0.0
        ) else {
            DiagnosticsLog.launcher.info("debugSimulateSearchFieldClick: failed to construct synthetic events")
            return
        }

        window.sendEvent(mouseDown)
        window.sendEvent(mouseUp)
        DiagnosticsLog.launcher.info("debugSimulateSearchFieldClick: after sendEvent, firstResponder=\(String(describing: window.firstResponder), privacy: .public), windowIsVisible=\(window.isVisible, privacy: .public), windowIsKey=\(window.isKeyWindow, privacy: .public)")
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

    /// Debug-only entry point (`LAUNCHPAD_DEBUG_SIMULATE_ITEM_DRAG`, wired
    /// in `AppDelegate`) — see `GridViewController.debugSimulateItemDrag`'s
    /// doc comment for why this exists.
    func debugSimulateItemDrag(mode: String) {
        gridViewController.debugSimulateItemDrag(mode: mode)
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

    @objc private func quickMenuButtonTapped() {
        let menu = NSMenu()

        let pagedItem = NSMenuItem(title: L10n.layoutModePaged, action: #selector(selectPagedLayoutMode), keyEquivalent: "")
        pagedItem.target = self
        pagedItem.state = gridModel.layoutMode == .paged ? .on : .off
        menu.addItem(pagedItem)

        let scrollItem = NSMenuItem(title: L10n.layoutModeVerticalScroll, action: #selector(selectVerticalScrollLayoutMode), keyEquivalent: "")
        scrollItem.target = self
        scrollItem.state = gridModel.layoutMode == .verticalScroll ? .on : .off
        menu.addItem(scrollItem)

        menu.addItem(.separator())
        let sortItem = NSMenuItem(title: L10n.sortByLabel, action: nil, keyEquivalent: "")
        let sortSubmenu = NSMenu()
        let modes: [(SortMode, String)] = [
            (.custom, L10n.sortModeCustom), (.name, L10n.sortModeName),
            (.dateAdded, L10n.sortModeDateAdded), (.lastUsed, L10n.sortModeLastUsed)
        ]
        for (mode, title) in modes {
            let mi = NSMenuItem(title: title, action: #selector(selectSortMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = mode.rawValue
            mi.state = gridModel.gridSettings.sortMode == mode ? .on : .off
            sortSubmenu.addItem(mi)
        }
        sortItem.submenu = sortSubmenu
        menu.addItem(sortItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: L10n.openSettingsMenuItem, action: #selector(settingsButtonTapped), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: quickMenuButton)
        }
    }

    @objc private func selectPagedLayoutMode() { applyLayoutMode(.paged) }
    @objc private func selectVerticalScrollLayoutMode() { applyLayoutMode(.verticalScroll) }

    private func applyLayoutMode(_ mode: LayoutMode) {
        gridModel.setLayoutMode(mode)
        Task { await gridModel.save() }
    }

    @objc private func selectSortMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = SortMode(rawValue: raw) else { return }
        gridModel.applySortMode(mode)
        Task { await gridModel.save() }
    }

    private func setSearchMode(active: Bool) {
        searchResultsScrollView.isHidden = !active
        gridViewController.view.isHidden = active
    }

    private func launch(_ record: ApplicationRecord) {
        // Every launch path (grid click, search result, folder contents)
        // funnels through here — the single place to stamp `lastUsed` for
        // `SortMode.lastUsed` (see `GridModel.recordLaunch`'s doc comment).
        gridModel.recordLaunch(for: record.id)
        Task { await gridModel.save() }
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
