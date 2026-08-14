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
    private let emptySearchResultsView = NSStackView()
    private var searchResultsBottomConstraint: NSLayoutConstraint?
    private var currentDockInset: CGFloat = 0
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
        // comment explains for the full-screen background. Real, confirmed
        // report ("検索バーのデザインが堅い"): the reference's own SwiftUI
        // source (`TSLayout.searchCorner` = 10) and its HTML mockup
        // disagree here (20pt/half-height in the HTML) — 10pt on a 36pt-tall
        // bar reads as a barely-rounded rectangle, not a soft capsule. Full
        // stadium shape (half the bar's own height) matches what the user
        // actually saw and asked for.
        let searchBarGlass = GlassBackgroundFactory.makeBackground(cornerRadius: 18)
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
        // 13.5pt — the reference's own `.font(.system(size: 13.5))`; the
        // previous 20pt was an invented value, not taken from the reference.
        searchField.font = .systemFont(ofSize: 13.5, weight: .regular)
        // Round 13 §E: confirmed via real measurement (`log stream` with
        // `LAUNCHPAD_DEBUG_SEARCH_FIELD_EDITING=1`) that without this, the
        // field editor's typed text falls back to `.controlTextColor` — a
        // flat, non-vibrancy-aware color meant for opaque controls, not
        // the translucent glass search bar it actually sits on. The
        // placeholder above already got this right via its explicit
        // `.placeholderTextColor`; `GridCellItem`'s app-name labels
        // (`Sources/Grid/GridCellItem.swift`) establish `.labelColor` as
        // this codebase's convention for legible text over glass/blur
        // materials — this was the one place that convention wasn't
        // followed, and is the root cause of "入力時だけ検索の文字がおかしい".
        searchField.textColor = .labelColor
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
        // quick menu's "Open Settings…" item, wired up below).
        //
        // The quick-menu button itself now lives *inside* the search bar's
        // own pill (trailing edge) instead of as a separate floating chip
        // beside it — matches the "Tessera" reference's `SearchField`
        // exactly, whose "•••" button is one more element in the same
        // `HStack` as the magnifying glass and text field, not a second
        // glass shape. Symbol is plain `ellipsis` (not `ellipsis.circle` —
        // the circle is drawn manually via the button's own layer, matching
        // the reference's `.background(.white.opacity(0.12), in: Circle())`),
        // 10pt bold, in a 20x20 circle.
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

        applySearchResultsLayoutMetrics()

        searchResultsCollectionView.collectionViewLayout = searchResultsLayout
        searchResultsCollectionView.dataSource = self
        searchResultsCollectionView.delegate = self
        searchResultsCollectionView.register(AppIconCollectionViewItem.self, forItemWithIdentifier: itemIdentifier)
        searchResultsCollectionView.isSelectable = true
        searchResultsCollectionView.backgroundColors = [.clear]
        searchResultsCollectionView.onBackgroundClick = { [weak self] in self?.onDidCancel() }

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
        searchResultsScrollView.hasVerticalScroller = true
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
        searchBar.addSubview(quickMenuButton)

        root.addSubview(searchBar)
        root.addSubview(gridViewController.view)
        root.addSubview(searchResultsScrollView)
        let searchResultsBottom = searchResultsScrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        searchResultsBottomConstraint = searchResultsBottom
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
            searchField.trailingAnchor.constraint(equalTo: quickMenuButton.leadingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),

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
            searchResultsBottom
        ])

        view = root
        viewModel.onChange = { [weak self] in
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

    /// Round 13 §E debug-only entry point (`LAUNCHPAD_DEBUG_TYPE_SEARCH_FIELD`,
    /// wired in `AppDelegate`) — `debugSetSearchQuery` sets `stringValue`
    /// directly and never attaches a real field editor, so it can't
    /// reproduce "検索欄が入力時だけおかしい" (only shows up while a real
    /// field editor is actively receiving characters). Focuses the field
    /// via `makeFirstResponder` (the same real API `viewDidAppear` already
    /// uses, not the synthetic click hook — see note below) to establish
    /// a real field editor, then dispatches real synthetic keyDown events
    /// per character so the field editor's layout is exercised exactly as
    /// it would be by a user typing.
    ///
    /// Deliberately does NOT reuse `debugSimulateSearchFieldClick`: while
    /// diagnosing this bug, that hook was found to hang indefinitely after
    /// dispatching its synthetic mouseDown — the process stays alive but
    /// never logs its "after sendEvent" line and stops responding. Root
    /// cause not yet investigated (likely `NSTextView.mouseDown`'s internal
    /// tracking loop blocking on a real subsequent event that the
    /// synchronously-issued synthetic mouseUp can't satisfy via
    /// `sendEvent`), and is a separate pre-existing issue from this
    /// Round's search-field-during-typing bug — flagged for follow-up, not
    /// fixed here to keep this diagnosis unblocked.
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
        searchResultsBottomConstraint?.constant = -dockInset
        applySearchResultsLayoutMetrics()
        view.layoutSubtreeIfNeeded()
    }

    /// Debug-only entry point (`LAUNCHPAD_DEBUG_SIMULATE_PAGE_DRAG`, wired
    /// in `AppDelegate`) — see `GridViewController.debugSimulatePageDrag`'s
    /// doc comment for why this exists.
    func debugSimulatePageDrag(commit: Bool) {
        gridViewController.debugSimulatePageDrag(commit: commit)
    }

    /// Debug-only entry point (`LAUNCHPAD_DEBUG_OPEN_FIRST_FOLDER`, wired
    /// in `AppDelegate`) — see `GridViewController.debugOpenFirstFolder`'s
    /// doc comment for why this exists.
    func debugOpenFirstFolder() {
        gridViewController.debugOpenFirstFolder()
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
        let itemCount = viewModel.filteredRecords.count
        let isSingleRowResultSet = !viewModel.query.isEmpty
            && itemCount > 0
            && itemCount <= max(settings.columns, 1)
        let viewport = searchResultsScrollView.contentView.bounds.size
        let contentWidth = CGFloat(itemCount) * itemSize.width
            + CGFloat(max(itemCount - 1, 0)) * CGFloat(settings.horizontalSpacing)
        let horizontalInset = isSingleRowResultSet
            ? max(margin, (viewport.width - contentWidth) / 2)
            : margin
        let verticalInset = isSingleRowResultSet
            ? max(margin, (viewport.height - itemSize.height) / 2)
            : margin
        // The scroll view's bottom constraint already moves up by
        // `currentDockInset` in `refreshDockLayout()`. Keep the collection
        // view's own section inset to the persistent page margin only; adding
        // the Dock inset here as well would reserve that height twice.
        let insets = NSEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
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
        emptySearchResultsView.isHidden = viewModel.query.isEmpty || !viewModel.filteredRecords.isEmpty
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

    /// Round 13 §E: diagnoses "検索欄が入力時だけおかしい" — `SearchFieldCell
    /// .drawingRect(forBounds:)` only governs the non-editing display
    /// (placeholder/committed text); while a real field editor `NSTextView`
    /// is attached during active typing, its own `textContainerInset` is a
    /// separate value this override never touches. Logs both sides so the
    /// mismatch (if any) shows up in `log stream` instead of being guessed
    /// at — gated behind `LAUNCHPAD_DEBUG_SEARCH_FIELD_EDITING` since this
    /// fires on every keystroke.
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
        guard let index = indexPaths.first?.item else { return }
        if index == viewModel.selectedIndex {
            launchSearchSelection()
        } else {
            viewModel.select(index: index)
        }
    }
}
