import AppKit
import Catalog
import DesignSystem
import Diagnostics
import Grid
import Localization
import Persistence
import UniformTypeIdentifiers

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
    private let clearSearchButton = NSButton()
    private let quickMenuButton = NSButton()
    private let searchResultsCollectionView = SearchResultsCollectionView()
    private let searchResultsScrollView = NSScrollView()
    private let searchResultsLayout = NSCollectionViewFlowLayout()
    private let searchPageControl = PageControlView(frame: .zero)
    private let emptySearchResultsView = NSStackView()
    private var searchPageControlBottomConstraint: NSLayoutConstraint?
    private var currentDockInset: CGFloat = 0
    private var searchCurrentPage = 0
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

        let searchBarGlass = GlassSurfaceFactory.makeBackground(cornerRadius: 18)
        searchBarGlass.translatesAutoresizingMaskIntoConstraints = false

        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        // 12.5pt medium + opacity 0.65 — the reference's own
        // `Image(systemName: "magnifyingglass").font(.system(size: 12.5,
        // weight: .medium)).foregroundStyle(.white.opacity(0.65))`; the
        // previous 16pt was an invented value, not taken from the reference.
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12.5, weight: .medium))
        searchIcon.contentTintColor = NSColor.white.withAlphaComponent(0.65)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.cell = SearchFieldCell()
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
        // 13.5pt — the reference's own `.font(.system(size: 13.5))`; the
        // previous 20pt was an invented value, not taken from the reference.
        searchField.font = .systemFont(ofSize: 13.5, weight: .regular)
        searchField.textColor = .labelColor
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.setAccessibilityLabel(L10n.searchAccessibilityLabel)

        quickMenuButton.translatesAutoresizingMaskIntoConstraints = false
        quickMenuButton.bezelStyle = .circular
        quickMenuButton.isBordered = false
        quickMenuButton.wantsLayer = true
        quickMenuButton.layer?.cornerRadius = 10
        quickMenuButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        quickMenuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: L10n.quickMenuAccessibilityLabel)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        quickMenuButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        quickMenuButton.target = self
        quickMenuButton.action = #selector(quickMenuButtonTapped)

        clearSearchButton.translatesAutoresizingMaskIntoConstraints = false
        clearSearchButton.bezelStyle = .circular
        clearSearchButton.isBordered = false
        clearSearchButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: L10n.clearSearchAccessibilityLabel
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        clearSearchButton.contentTintColor = NSColor.white.withAlphaComponent(0.62)
        clearSearchButton.target = self
        clearSearchButton.action = #selector(clearSearchButtonTapped)
        clearSearchButton.isHidden = true

        applySearchResultsLayoutMetrics()

        searchResultsCollectionView.collectionViewLayout = searchResultsLayout
        searchResultsCollectionView.dataSource = self
        searchResultsCollectionView.delegate = self
        searchResultsCollectionView.register(AppIconCollectionViewItem.self, forItemWithIdentifier: itemIdentifier)
        searchResultsCollectionView.isSelectable = true
        searchResultsCollectionView.backgroundColors = [.clear]
        searchResultsCollectionView.onBackgroundClick = { [weak self] in self?.onDidCancel() }
        searchResultsScrollView.hasVerticalScroller = false
        searchResultsScrollView.hasHorizontalScroller = false
        searchResultsScrollView.verticalScrollElasticity = .none
        searchResultsScrollView.horizontalScrollElasticity = .none

        searchPageControl.translatesAutoresizingMaskIntoConstraints = false
        searchPageControl.isHidden = true
        searchPageControl.onSelectPage = { [weak self] page in self?.selectSearchPage(page) }
        searchPageControl.onPrevious = { [weak self] in self?.selectSearchPage((self?.searchCurrentPage ?? 0) - 1) }
        searchPageControl.onNext = { [weak self] in self?.selectSearchPage((self?.searchCurrentPage ?? 0) + 1) }

        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.setAccessibilityElement(false)

        let emptyTitle = NSTextField(labelWithString: L10n.searchNoResultsTitle)
        emptyTitle.font = .systemFont(ofSize: 14, weight: .medium)
        emptyTitle.textColor = .secondaryLabelColor
        emptyTitle.alignment = .center
        emptyTitle.setAccessibilityElement(false)

        let emptyMessage = NSTextField(labelWithString: L10n.searchNoResultsMessage)
        emptyMessage.font = .systemFont(ofSize: 12)
        emptyMessage.textColor = .tertiaryLabelColor
        emptyMessage.alignment = .center
        emptyMessage.setAccessibilityElement(false)

        // `backgroundView` is inserted by NSCollectionView after assignment,
        // so it has no common ancestor with the collection view while
        // `loadView()` is building the hierarchy. Use a frame/autoresizing
        // contract instead of cross-view Auto Layout constraints.
        emptySearchResultsView.translatesAutoresizingMaskIntoConstraints = true
        emptySearchResultsView.orientation = .vertical
        emptySearchResultsView.alignment = .centerX
        emptySearchResultsView.spacing = 4
        emptySearchResultsView.addArrangedSubview(emptyIcon)
        emptySearchResultsView.addArrangedSubview(emptyTitle)
        emptySearchResultsView.addArrangedSubview(emptyMessage)
        emptySearchResultsView.setAccessibilityElement(true)
        emptySearchResultsView.setAccessibilityRole(.group)
        emptySearchResultsView.setAccessibilityLabel(L10n.searchNoResultsTitle)
        emptySearchResultsView.setAccessibilityHelp(L10n.searchNoResultsMessage)
        emptySearchResultsView.isHidden = true
        emptySearchResultsView.frame = searchResultsCollectionView.bounds
        emptySearchResultsView.autoresizingMask = [.width, .height]
        searchResultsCollectionView.backgroundView = emptySearchResultsView

        searchResultsScrollView.translatesAutoresizingMaskIntoConstraints = false
        searchResultsScrollView.documentView = searchResultsCollectionView
        searchResultsScrollView.drawsBackground = false
        // Search is paged like the main grid. A scroller here is both
        // misleading and visually competes with the page control; the
        // collection view is intentionally limited to one page of items.
        searchResultsScrollView.hasVerticalScroller = false
        searchResultsScrollView.isHidden = true

        addChild(gridViewController)
        gridViewController.view.translatesAutoresizingMaskIntoConstraints = false

        // Plain positioning container (not glass itself) — holds the glass
        // shape plus every real interactive control (icon, field, quick-menu
        // button) as siblings drawn on top of it, so the pill reads as one
        // floating piece of glass while every click still hits a normal
        // AppKit control directly. One pill holding all three, not a
        // separate chip for the quick-menu button, matches the reference's
        // `SearchField` exactly (see the controls' own doc comments above).
        let searchBar = NSView()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(searchBarGlass)
        searchBar.addSubview(searchIcon)
        searchBar.addSubview(searchField)
        searchBar.addSubview(clearSearchButton)
        searchBar.addSubview(quickMenuButton)

        root.addSubview(searchBar)
        root.addSubview(gridViewController.view)
        root.addSubview(searchResultsScrollView)
        root.addSubview(searchPageControl)
        let searchPageControlBottom = searchPageControl.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)
        searchPageControlBottomConstraint = searchPageControlBottom
        NSLayoutConstraint.activate([
            // 300x36 — `TSLayout.searchWidth`/`searchHeight` from the
            // reference exactly; the previous 400x44 was an invented value.
            searchBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
            searchBar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            searchBar.widthAnchor.constraint(equalToConstant: 300),
            searchBar.heightAnchor.constraint(equalToConstant: 36),

            searchBarGlass.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor),
            searchBarGlass.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor),
            searchBarGlass.topAnchor.constraint(equalTo: searchBar.topAnchor),
            searchBarGlass.bottomAnchor.constraint(equalTo: searchBar.bottomAnchor),

            // 12pt leading inset — the reference's `.padding(.leading, 12)`.
            searchIcon.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 12),
            // SF Symbol "magnifyingglass" has its handle in the lower-right,
            // so its optical center sits slightly up-left of the glyph's
            // true geometric center — nudge centerY up by 1pt to compensate.
            searchIcon.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor, constant: -1),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),

            // 8pt gap — the reference's `HStack(spacing: 8)`.
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: clearSearchButton.leadingAnchor, constant: -6),
            searchField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),

            clearSearchButton.trailingAnchor.constraint(equalTo: quickMenuButton.leadingAnchor, constant: -6),
            clearSearchButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            clearSearchButton.widthAnchor.constraint(equalToConstant: 20),
            clearSearchButton.heightAnchor.constraint(equalToConstant: 20),

            // 20x20 circle, 8pt trailing inset — the reference's own
            // `.frame(width: 20, height: 20)` button + `.padding(.trailing, 8)`.
            quickMenuButton.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -8),
            quickMenuButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            quickMenuButton.widthAnchor.constraint(equalToConstant: 20),
            quickMenuButton.heightAnchor.constraint(equalToConstant: 20),

            gridViewController.view.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 30),
            gridViewController.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            gridViewController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            gridViewController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            searchResultsScrollView.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 30),
            searchResultsScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchResultsScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchResultsScrollView.bottomAnchor.constraint(equalTo: searchPageControl.topAnchor, constant: -8),

            searchPageControl.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            searchPageControlBottom,
            searchPageControl.widthAnchor.constraint(equalToConstant: 240),
            searchPageControl.heightAnchor.constraint(equalToConstant: 32)
        ])

        view = root
        viewModel.onChange = { [weak self] in
            self?.syncSearchPage()
            self?.searchResultsCollectionView.reloadData()
            self?.updateSearchResultsPresentation()
            self?.applySearchResultsLayoutMetrics()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applySearchResultsLayoutMetrics()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applySearchResultsLayoutMetrics()
        DiagnosticsLog.launcher.info("viewDidAppear layout: root=\(String(describing: self.view.frame), privacy: .public), grid=\(String(describing: self.gridViewController.view.frame), privacy: .public), searchField=\(String(describing: self.searchField.convert(self.searchField.bounds, to: self.view)), privacy: .public)")

        // AppKit can still be resolving the hosting hierarchy while
        // viewDidAppear runs. Moving first-responder installation to the next
        // MainActor turn avoids re-entering layout while preserving immediate
        // keyboard search focus.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.searchField)
        }
    }

    func resetSearch() {
        searchField.stringValue = ""
        viewModel.setQuery("")
        setSearchMode(active: false)
        gridViewController.resetDragStateIfNeeded()
        // Same guarantee for item drags. Without this, a drag left active by a
        // trigger that hid the launcher mid-gesture stayed active, and only the
        // 15s fallback timer would eventually clear it.
        gridViewController.cancelItemDragIfNeeded()
        // Same reasoning as the drag reset above: a folder left open when the
        // launcher was dismissed must not leave the grid hidden next time.
        gridViewController.setGridContentHidden(false)
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    func debugSetSearchQuery(_ query: String) {
        searchField.stringValue = query
        applyQuery(query)
    }

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

    func debugSimulateSearchFieldTyping(_ text: String) {
        guard let window = view.window else {
            DiagnosticsLog.launcher.info("debugSimulateSearchFieldTyping: no window")
            return
        }
        window.makeFirstResponder(searchField)
        for character in text {
            let characters = String(character)
            guard let keyDown = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: 0
            ) else { continue }
            window.sendEvent(keyDown)
        }
        logSearchFieldEditingGeometryIfEnabled(context: "afterDebugTyping")
    }

    func reloadGrid() {
        gridViewController.reload()
        applySearchResultsLayoutMetrics()
    }

    func refreshDockLayout() {
        let dockInset = gridViewController.refreshDockLayout()
        guard abs(currentDockInset - dockInset) > 0.5 else { return }
        currentDockInset = dockInset
        searchPageControlBottomConstraint?.constant = -(dockInset + 24)
        applySearchResultsLayoutMetrics()
        view.layoutSubtreeIfNeeded()
    }

    private var searchPageSize: Int {
        max(gridModel.gridSettings.columns, 1) * max(gridModel.gridSettings.rows, 1)
    }

    private var searchPageCount: Int {
        max((viewModel.filteredRecords.count + searchPageSize - 1) / searchPageSize, 1)
    }

    private func searchRecordsOnCurrentPage() -> [ApplicationRecord] {
        let start = min(searchCurrentPage * searchPageSize, viewModel.filteredRecords.count)
        let end = min(start + searchPageSize, viewModel.filteredRecords.count)
        return Array(viewModel.filteredRecords[start..<end])
    }

    private func syncSearchPage() {
        let previousPage = searchCurrentPage
        let pageCount = searchPageCount
        if let selectedIndex = viewModel.selectedIndex {
            searchCurrentPage = min(max(selectedIndex / searchPageSize, 0), pageCount - 1)
        } else {
            searchCurrentPage = min(searchCurrentPage, pageCount - 1)
        }
        searchPageControl.numberOfPages = pageCount
        searchPageControl.currentPage = searchCurrentPage
        if previousPage != searchCurrentPage {
            searchResultsScrollView.contentView.bounds.origin = .zero
        }
    }

    private func selectSearchPage(_ page: Int) {
        guard !viewModel.filteredRecords.isEmpty else { return }
        let nextPage = min(max(page, 0), searchPageCount - 1)
        guard nextPage != searchCurrentPage else { return }
        searchCurrentPage = nextPage
        searchPageControl.currentPage = nextPage
        searchResultsScrollView.contentView.bounds.origin = .zero
        searchResultsCollectionView.reloadData()
        applySearchResultsLayoutMetrics()
    }

    /// Debug-only entry point (`LAUNCHPAD_DEBUG_SIMULATE_PAGE_DRAG`, wired
    /// in `AppDelegate`) — see `GridViewController.debugSimulatePageDrag`'s
    /// doc comment for why this exists.
    func debugSimulatePageDrag(commit: Bool) {
        gridViewController.debugSimulatePageDrag(commit: commit)
    }

    /// Debug-only entry point (`LAUNCHPAD_DEBUG_OPEN_FIRST_FOLDER`, wired
    /// in `AppDelegate`) — see `GridViewController.debugOpenFolder`'s
    /// doc comment for why this exists.
    func debugOpenFolder(ordinal: Int) {
        gridViewController.debugOpenFolder(ordinal: ordinal)
    }

    /// Debug-only entry point (`LAUNCHPAD_DEBUG_SIMULATE_ITEM_DRAG`, wired
    /// in `AppDelegate`) — see `GridViewController.debugSimulateItemDrag`'s
    /// doc comment for why this exists.
    func debugSimulateItemDrag(mode: String) {
        gridViewController.debugSimulateItemDrag(mode: mode)
    }

    private func applySearchResultsLayoutMetrics() {
        let cellSize = gridViewController.currentCellSize
        let settings = gridModel.gridSettings
        let itemSize = cellSize.width > 0 && cellSize.height > 0
            ? cellSize
            : NSSize(width: 96, height: 110) // before the grid's first layout pass
        let margin = CGFloat(settings.pageMargins)
        // The scroll view's bottom constraint already moves up by
        // `currentDockInset` in `refreshDockLayout()`. Keep the collection
        // view's own section inset to the persistent page margin only; adding
        // the Dock inset here as well would reserve that height twice.
        let insets = NSEdgeInsets(
            top: margin,
            left: margin,
            bottom: margin,
            right: margin
        )

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

    private func updateSearchResultsPresentation() {
        clearSearchButton.isHidden = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let showsEmptyState = !viewModel.query.isEmpty && viewModel.filteredRecords.isEmpty
        emptySearchResultsView.isHidden = !showsEmptyState
        emptySearchResultsView.setAccessibilityElement(showsEmptyState)
        searchPageControl.isHidden = viewModel.query.isEmpty || viewModel.filteredRecords.isEmpty
    }

    @objc private func settingsButtonTapped() {
        onOpenSettings()
    }

    @objc private func quickMenuButtonTapped() {
        let menu = NSMenu()

        let pagedItem = NSMenuItem(title: L10n.layoutModePaged, action: #selector(selectPagedLayoutMode), keyEquivalent: "")
        pagedItem.target = self
        pagedItem.state = .on
        menu.addItem(pagedItem)

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

    @objc private func clearSearchButtonTapped() {
        resetSearch()
        view.window?.makeFirstResponder(searchField)
    }

    @objc private func selectPagedLayoutMode() { applyLayoutMode(.paged) }

    private func applyLayoutMode(_ mode: LayoutMode) {
        let supportedMode: LayoutMode = mode == .verticalScroll ? .paged : mode
        gridModel.setLayoutMode(supportedMode)
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
        updateSearchResultsPresentation()
    }

    private func launch(_ record: ApplicationRecord) {
        // Every launch path (grid click, search result, folder contents)
        // funnels through here — the single place to stamp `lastUsed` for
        // `SortMode.lastUsed` (see `GridModel.recordLaunch`'s doc comment).
        gridModel.recordLaunch(for: record.id)
        Task { await gridModel.save() }
        AppLauncher.launch(record)
        // Dismiss immediately rather than from a launch-completion callback.
        // `NSWorkspace.openApplication`'s completion handler doesn't fire when
        // the *request* is accepted — it fires once the app has actually
        // finished launching, which for a cold start is hundreds of
        // milliseconds to several seconds. Waiting for it left the full-screen
        // overlay sitting on top of the app the user just opened for that
        // whole time. The click already settles the user's intent, so the
        // overlay leaves on the click, matching the real Launchpad.
        onDidLaunch()
    }

    // MARK: NSTextFieldDelegate

    /// Large display text wants slightly negative tracking (Apple's own
    /// type-detail guidance — at 20pt, zero/positive tracking reads too
    /// loose). `NSTextField` has no direct kerning property for live-typed
    /// text; the field editor's `typingAttributes` is the actual hook.
    func controlTextDidBeginEditing(_ obj: Notification) {
        if let fieldEditor = obj.userInfo?["NSFieldEditor"] as? NSTextView {
            fieldEditor.typingAttributes[.kern] = -0.4
            logSearchFieldEditingGeometryIfEnabled(context: "didBeginEditing")
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applyQuery(searchField.stringValue)
        logSearchFieldEditingGeometryIfEnabled(context: "didChange")
    }

    private func logSearchFieldEditingGeometryIfEnabled(context: String) {
        guard ProcessInfo.processInfo.environment["LAUNCHPAD_DEBUG_SEARCH_FIELD_EDITING"] == "1" else { return }
        let fieldEditor = view.window?.fieldEditor(false, for: searchField) as? NSTextView
        let cellDrawingRect = (searchField.cell as? SearchFieldCell)?.drawingRect(forBounds: searchField.bounds)
        DiagnosticsLog.launcher.info("""
            searchFieldEditingGeometry[\(context, privacy: .public)]: fieldEditor.frame=\(String(describing: fieldEditor?.frame), privacy: .public), fieldEditor.textContainerInset=\(String(describing: fieldEditor?.textContainerInset), privacy: .public), cellDrawingRect=\(String(describing: cellDrawingRect), privacy: .public), searchField.bounds=\(String(describing: self.searchField.bounds), privacy: .public), searchField.textColor=\(String(describing: self.searchField.textColor), privacy: .public), fieldEditor.textColor=\(String(describing: fieldEditor?.textColor), privacy: .public), fieldEditor.typingAttributes=\(String(describing: fieldEditor?.typingAttributes), privacy: .public), fieldEditor.string=\(String(describing: fieldEditor?.string), privacy: .public)
            """)
    }

    private func applyQuery(_ query: String) {
        viewModel.setQuery(query)
        applySearchResultsLayoutMetrics()
        setSearchMode(active: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let inSearchMode = !searchResultsScrollView.isHidden
        let searchRowLength = max(gridModel.gridSettings.columns, 1)
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if inSearchMode {
                viewModel.moveSelection(by: searchRowLength)
            } else {
                gridViewController.moveSelection(deltaColumns: 0, deltaRows: 1)
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if inSearchMode {
                viewModel.moveSelection(by: -searchRowLength)
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
            cancelSearchOrDismiss()
            return true
        default:
            return false
        }
    }

    func cancelSearchOrDismiss() {
        if !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resetSearch()
            view.window?.makeFirstResponder(searchField)
        } else {
            onDidCancel()
        }
    }

    private func launchSearchSelection() {
        guard let record = viewModel.selectedRecord else { return }
        launch(record)
    }

    // MARK: NSCollectionViewDataSource (search results only)

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        searchRecordsOnCurrentPage().count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let item = collectionView.makeItem(withIdentifier: itemIdentifier, for: indexPath) as? AppIconCollectionViewItem else {
            return NSCollectionViewItem()
        }
        let pageRecords = searchRecordsOnCurrentPage()
        guard pageRecords.indices.contains(indexPath.item) else { return item }
        let record = pageRecords[indexPath.item]
        let globalIndex = searchCurrentPage * searchPageSize + indexPath.item
        let isSelected = viewModel.selectedIndex == globalIndex
        let iconSize = gridViewController.currentIconSize
        let visualScale = gridViewController.currentEffectiveIconScale
        let cache = iconCache
        let expectedKey = record.iconCacheKey
        // Settle synchronously on a cache hit. Results reload on *every*
        // keystroke, and unconditionally configuring with the generic bundle
        // icon first meant every visible cell repainted as the generic icon
        // for a frame before its real icon came back through the task — while
        // typing, that reads as the whole result list flickering. Anything the
        // user has already seen is normally in the memory cache by now, so the
        // hit path is the common one; it also skips a per-cell task and a
        // synchronous `NSWorkspace.shared.icon(for:)` call.
        if let cached = cache.cachedIconIfAvailable(for: record) {
            item.configure(record: record, icon: cached, isSelected: isSelected, iconSize: iconSize, visualScale: visualScale)
        } else {
            item.configure(record: record, icon: NSWorkspace.shared.icon(for: .applicationBundle), isSelected: isSelected, iconSize: iconSize, visualScale: visualScale)
            Task { @MainActor in
                let icon = await cache.icon(for: record)
                // Search results reload on every keystroke, recycling cells —
                // same cell-reuse guard as Grid.GridCellItem, see its comment.
                guard item.currentRequestKey == expectedKey else { return }
                item.configure(record: record, icon: icon, isSelected: isSelected, iconSize: iconSize, visualScale: visualScale)
            }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let localIndex = indexPaths.first?.item else { return }
        let index = searchCurrentPage * searchPageSize + localIndex
        if index == viewModel.selectedIndex {
            launchSearchSelection()
        } else {
            viewModel.select(index: index)
        }
    }
}
