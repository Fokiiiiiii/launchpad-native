import AppKit
import Catalog
import Diagnostics
import Localization
import Persistence
import WindowBrowser


public final class GridViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let itemIdentifier = NSUserInterfaceItemIdentifier("GridCellItem")

    private let model: GridModel
    private let iconCache: IconCache
    private var prefetchTask: Task<Void, Never>?
    private var prefetchGeneration = 0
    /// Bounds the usual four-page working set (35 items per page by default)
    /// with room for folder previews; larger/custom pages may exceed it.
    private static let maxPrefetchIcons = 160
    private let onLaunch: (ApplicationRecord) -> Void
    private let onBackgroundClick: () -> Void
    private let onRequestUninstall: (String) -> Void

    private let collectionView = GridCollectionView()
    private let scrollView = NSScrollView()
    private let pageControl = PageControlView()
    private var pageControlBottomConstraint: NSLayoutConstraint?
    private let layout = PagedGridLayout()
    private var dockReservedHeight: CGFloat = 0
    private var dockLayoutNeedsPass = false

    private var currentPage = 0
    private lazy var folderOverlay = FolderOverlayPresenter(model: model, iconCache: iconCache)
    private let windowThumbnailService = WindowThumbnailService()


    /// Only the one snapshot actually needed (whichever neighbor the drag
    /// direction reveals), created lazily once direction is known — not
    /// pre-rendered for both sides up front.
    private var dragNeighborView: NSView?
    /// `0` = direction not yet known this gesture, `1` = revealing the next
    /// page, `-1` = revealing the previous page.
    private var dragDirection = 0
    private var dragHasPrev = false
    private var dragHasNext = false
    /// Bumped on every begin/finish/force-reset so a stale fallback timer
    /// or settle callback from a previous gesture can recognize it's stale
    /// and no-op instead of undoing a newer gesture's state.
    private var dragGeneration = 0
    /// The page `endPageDrag` has already committed to (or `nil` if the
    /// current/most recent drag settled with no page change) — set right
    /// before scheduling `finishPageDrag`'s async settle-timed call, so
    /// `beginPageDrag` can complete a still-settling previous drag
    /// *immediately and correctly* (landing on the page it actually
    /// committed to) instead of either dropping the new swipe or finishing
    /// onto the stale pre-transition page.
    private var pendingPageDragTargetPage: Int?
    /// Last-resort recovery bound for `beginPageDrag`'s fallback timer —
    /// see the doc comment there for why this must be far longer than any
    /// real gesture, not a tight "feels responsive" value.
    private static let dragSafetyNetTimeout: TimeInterval = 30.0

    public init(
        model: GridModel,
        iconCache: IconCache,
        onLaunch: @escaping (ApplicationRecord) -> Void,
        onBackgroundClick: @escaping () -> Void,
        onRequestUninstall: @escaping (String) -> Void = { _ in }
    ) {
        self.model = model
        self.iconCache = iconCache
        self.onLaunch = onLaunch
        self.onBackgroundClick = onBackgroundClick
        self.onRequestUninstall = onRequestUninstall
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    deinit {
        prefetchTask?.cancel()
    }

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        layout.settings = model.gridSettings
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(GridCellItem.self, forItemWithIdentifier: itemIdentifier)
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.menuProvider = { [weak self] indexPath in self?.contextMenu(for: indexPath) }
        // All four bail while an icon is being dragged. A page change from
        // here does not tell the drag session about itself, so the dragged
        // item's cell — hidden on its own page by `beginItemDrag` — is rebuilt
        // at full opacity by `reloadData`, and the user sees the app twice:
        // once under the pointer, once back in its old slot. The page-swipe
        // machinery also drives the collection view's own transform, which the
        // drag's edge peek is already using. Dragging to a page edge is the
        // supported way to change pages mid-drag.
        collectionView.onSwipePage = { [weak self] delta in
            guard let self, !self.itemDrag.isDragging else { return }
            self.jumpToAdjacentPage(delta: delta)
        }
        collectionView.onSwipeBegan = { [weak self] in
            guard let self, !self.itemDrag.isDragging else { return }
            self.beginPageDrag()
        }
        collectionView.onSwipeChanged = { [weak self] delta in
            guard let self, !self.itemDrag.isDragging else { return }
            self.updatePageDrag(deltaX: delta)
        }
        collectionView.onSwipeEnded = { [weak self] delta, velocity in
            guard let self, !self.itemDrag.isDragging else { return }
            self.endPageDrag(deltaX: delta, velocity: velocity)
        }
        collectionView.onItemMouseDown = { [weak self] indexPath, event in self?.itemDrag.handleItemMouseDown(indexPath: indexPath, event: event) }
        collectionView.onItemMouseDragged = { [weak self] event in self?.itemDrag.handleItemMouseDragged(event: event) }
        collectionView.onItemMouseUp = { [weak self] event in self?.itemDrag.handleItemMouseUp(event: event) }
        collectionView.onBackgroundClick = { [weak self] in
            // Extra safety-net opportunity for the page-drag machinery (see
            // `resetDragStateIfNeeded`'s doc comment) — harmless no-op if
            // no drag is active.
            self?.resetDragStateIfNeeded()
            self?.itemDrag.cancelItemDragIfNeeded()
            self?.onBackgroundClick()
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.onSelectPage = { [weak self] index in self?.jumpToPage(index) }
        pageControl.onPrevious = { [weak self] in self?.jumpToAdjacentPage(delta: -1) }
        pageControl.onNext = { [weak self] in self?.jumpToAdjacentPage(delta: 1) }

        root.addSubview(scrollView)
        root.addSubview(pageControl)
        let pageControlBottom = pageControl.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)
        self.pageControlBottomConstraint = pageControlBottom
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: pageControl.topAnchor, constant: -8),

            pageControl.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            pageControlBottom,
            pageControl.widthAnchor.constraint(equalToConstant: 240),
            pageControl.heightAnchor.constraint(equalToConstant: 32)
        ])

        view = root
        model.onChange = { [weak self] in self?.reload() }
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        // refreshDockLayout() owns the Dock constraint and settles it before a
        // presentation pass. This hook only applies the already-settled cell
        // geometry after AppKit has committed the current viewport.
        refreshVisibleIconSizes()
    }

    /// Pushes the settled icon geometry onto cells built before it was known.
    ///
    /// A cell keeps its creation-time size until `reloadData()` replaces it, and
    /// the first layout pass runs before the Dock has been measured. On a cold
    /// start the reload that would fix that is the full catalog scan a second
    /// later, so icons sat oversized on screen and then snapped down
    /// ("初回起動時にアプリが一瞬だけ大きくなってから元のサイズに戻る").
    private func refreshVisibleIconSizes() {
        let cellSize = layout.currentCellSize
        guard cellSize.width > 0, cellSize.height > 0 else { return }
        let metrics = currentIconLayoutMetrics
        let iconSize = metrics.baseSize
        let visualScale = metrics.visualScale
        var changed = false
        for case let cell as GridCellItem in collectionView.visibleItems() {
            if cell.refreshIconSize(iconSize, visualScale: visualScale) {
                changed = true
            }
        }
        // Only when something actually moved: resolving the new constraints now
        // — rather than leaving `needsLayout` for the next pass — is what keeps
        // the correction from being visible. `refreshIconSize` reports no change
        // once the cells match, so this settles in one step instead of looping.
        guard changed else { return }
        collectionView.layoutSubtreeIfNeeded()
    }

    @discardableResult
    private func updatePageControlBottomMargin() -> CGFloat {
        guard let window = view.window, let screen = window.screen else { return dockReservedHeight }
        let screenDockReservedHeight = DockSafeArea.bottomInset(
            hideDock: model.hideDockWhileLauncherOpen,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            dockFrames: DockSafeArea.visibleBottomDockFrames(on: screen)
        )
        let windowBottomInset = max(window.frame.minY - screen.frame.minY, 0)
        let dockReservedHeight = max(screenDockReservedHeight - windowBottomInset, 0)
        self.dockReservedHeight = dockReservedHeight
        let bottomConstant = -(dockReservedHeight + 24)
        guard abs((pageControlBottomConstraint?.constant ?? bottomConstant) - bottomConstant) > 0.5 else {
            return dockReservedHeight
        }
        pageControlBottomConstraint?.constant = bottomConstant
        dockLayoutNeedsPass = true
        DiagnosticsLog.grid.info(
            "page control inset: hideDock=\(self.model.hideDockWhileLauncherOpen, privacy: .public), screenDockReservedHeight=\(screenDockReservedHeight, privacy: .public), windowBottomInset=\(windowBottomInset, privacy: .public), dockReservedHeight=\(dockReservedHeight, privacy: .public), bottomConstant=\(bottomConstant, privacy: .public), screenFrame=\(String(describing: screen.frame), privacy: .public), visibleFrame=\(String(describing: screen.visibleFrame), privacy: .public)"
        )
        return dockReservedHeight
    }

    /// Re-samples the real Dock frame after WindowServer has settled a newly
    /// shown launcher. The public hook lets the window controller request a
    /// second pass without exposing the collection view or its layout.
    @discardableResult
    public func refreshDockLayout() -> CGFloat {
        let dockInset = updatePageControlBottomMargin()
        guard dockLayoutNeedsPass else { return dockInset }
        dockLayoutNeedsPass = false

        // The constraint change above must be consumed before any cell is
        // created. Invalidate first, then run one synchronous layout pass;
        // this replaces the old 40ms delayed reflow that made the first frame
        // use a larger cell and the next frame use a smaller one.
        layout.invalidateLayout()
        collectionView.collectionViewLayout?.invalidateLayout()
        view.layoutSubtreeIfNeeded()
        collectionView.layoutSubtreeIfNeeded()
        refreshVisibleIconSizes()
        return dockInset
    }

    public func reload() {
        layout.settings = model.gridSettings
        if currentPage >= model.pages.count {
            currentPage = max(model.pages.count - 1, 0)
        }
        collectionView.reloadData()
        pageControl.numberOfPages = model.pages.count
        pageControl.currentPage = currentPage
        // The bottom inset depends only on the Dock, never on the model, and
        // computing it enumerates every window on the system plus a
        // LaunchServices lookup. `model.onChange` routes here from 20-odd
        // mutations (every icon move, folder edit, rename, catalog reconcile),
        // so recomputing it here made a single drag-and-drop pay that cost.
        // The paths where the Dock can actually differ — `viewDidAppear`,
        // `viewDidLayout`, `refreshDockLayout` — still recompute it.
        prefetchAdjacentPageIcons()
    }

    private func prefetchAdjacentPageIcons(including targetPage: Int? = nil) {
        prefetchGeneration &+= 1
        let generation = prefetchGeneration
        prefetchTask?.cancel()

        var records: [ApplicationRecord] = []
        records.reserveCapacity(Self.maxPrefetchIcons)
        var seenIconKeys = Set<String>()
        var primaryApps: [ApplicationRecord] = []
        var remainingApps: [ApplicationRecord] = []
        var folderPreviews: [ApplicationRecord] = []
        func append(_ record: ApplicationRecord, to cohort: inout [ApplicationRecord]) {
            guard records.count < Self.maxPrefetchIcons,
                  seenIconKeys.insert(record.iconCacheKey).inserted else { return }
            // An icon already in memory needs no prefetch. `reload()` runs on
            // every model mutation — an icon moved, a folder renamed, a
            // catalog reconcile — so without this the warm case rebuilt a
            // task group of ~100 awaits that each resolved to a cache hit.
            guard iconCache.cachedIconIfAvailable(for: record) == nil else { return }
            records.append(record)
            cohort.append(record)
        }
        // Warm the visible page as well as likely targets. Explicit targets
        // come first so a jump spends the bounded budget on what will render.
        var pages = [currentPage, currentPage + 1, currentPage - 1]
        if let targetPage {
            pages.removeAll { $0 == targetPage }
            pages.insert(targetPage, at: 0)
        }
        // Then everything else, still in priority order. Paging is not the
        // only way onto a page — the dots jump straight to one — and a page
        // reached that way had never been warmed at all, so its icons filled
        // in a moment after it appeared. The budget below is what bounds this;
        // for an ordinary catalog it covers every page.
        pages.append(contentsOf: model.pages.indices)
        var seenPages = Set<Int>()
        let selectedPages = pages.filter {
            model.pages.indices.contains($0) && seenPages.insert($0).inserted
        }
        // Top-level apps from the target/current page get the first cohort.
        if let page = selectedPages.first {
            for item in model.pages[page] {
                guard case .app(let id) = item,
                      let record = model.record(for: id) else { continue }
                append(record, to: &primaryApps)
                if records.count == Self.maxPrefetchIcons { break }
            }
        }
        if records.count < Self.maxPrefetchIcons {
            // Remaining pages form the second cohort. Folder previews stay
            // last so they cannot delay primary icon loads.
            for page in selectedPages.dropFirst() {
                for item in model.pages[page] {
                    guard case .app(let id) = item,
                          let record = model.record(for: id) else { continue }
                    append(record, to: &remainingApps)
                    if records.count == Self.maxPrefetchIcons { break }
                }
                if records.count == Self.maxPrefetchIcons { break }
            }
        }
        if records.count < Self.maxPrefetchIcons {
            for page in selectedPages {
                for item in model.pages[page] {
                    guard case .folder(let folderID) = item,
                          let folder = model.folders[folderID] else { continue }
                    for child in folder.pages.flatMap({ $0 }).prefix(9) {
                        guard case .app(let id) = child,
                              let record = model.record(for: id) else { continue }
                        append(record, to: &folderPreviews)
                        if records.count == Self.maxPrefetchIcons { break }
                    }
                    if records.count == Self.maxPrefetchIcons { break }
                }
                if records.count == Self.maxPrefetchIcons { break }
            }
        }
        let cohorts = [primaryApps, remainingApps, folderPreviews].filter { !$0.isEmpty }
        guard !cohorts.isEmpty else { return }

        let cache = iconCache
        prefetchTask = Task { @MainActor [weak self, cache, cohorts] in
            // Start immediately. The old fixed delay left the first frame of
            // the next page cold, which was the visible icon pop-in.
            // IconCache already caps its worker queue at a finite number of
            // operations.
            // Keep priority cohorts sequential while each cohort remains
            // concurrent; this preserves target-first warmup under load.
            for cohort in cohorts {
                guard !Task.isCancelled else { return }
                await withTaskGroup(of: Void.self) { group in
                    for record in cohort {
                        // An earlier cohort — or a cell that scrolled into
                        // view while this one waited — may have warmed it
                        // since the list was built.
                        guard cache.cachedIconIfAvailable(for: record) == nil else { continue }
                        group.addTask {
                            _ = await cache.icon(for: record)
                        }
                    }
                }
            }

            guard let self, self.prefetchGeneration == generation else { return }
            self.prefetchTask = nil
        }
    }

    private var keyboardSelectionActive = false


    public func moveSelection(deltaColumns: Int, deltaRows: Int) {
        guard let current = collectionView.selectionIndexPaths.first else {
            select(IndexPath(item: 0, section: 0))
            return
        }
        let columns = max(model.gridSettings.columns, 1)
        var flat = current.item + deltaColumns + deltaRows * columns
        let count = model.pages.indices.contains(currentPage) ? model.pages[currentPage].count : 0

        if flat < 0 {
            guard currentPage > 0 else { return }
            jumpToPage(currentPage - 1)
            flat = max(model.pages[currentPage].count - 1, 0)
        } else if flat >= count {
            guard currentPage < model.pages.count - 1 else { return }
            jumpToPage(currentPage + 1)
            flat = 0
        }
        select(IndexPath(item: flat, section: 0))
    }

    public func launchSelection() {
        guard let indexPath = collectionView.selectionIndexPaths.first else { return }
        activate(at: indexPath)
    }

    private func select(_ indexPath: IndexPath) {
        guard model.pages.indices.contains(currentPage),
              model.pages[currentPage].indices.contains(indexPath.item) else { return }
        keyboardSelectionActive = true
        let previous = collectionView.selectionIndexPaths
        collectionView.selectionIndexPaths = [indexPath]
        applySelectionToLiveCells(selected: indexPath, clearing: previous)
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
    }

    /// Paints the selection onto the cells that already exist rather than
    /// reloading them. `reloadItems` replaces the view a cell is made of, and
    /// asking for that mid-interaction is what once broke item dragging
    /// outright — but it also simply does not repaint here: the reload is
    /// batched, so a selection moved by the arrow keys did not appear until
    /// something else happened to rebuild the page.
    private func applySelectionToLiveCells(selected: IndexPath, clearing previous: Set<IndexPath>) {
        for path in previous.union([selected]) {
            (collectionView.item(at: path) as? GridCellItem)?.applySelection(path == selected)
        }
    }

    /// Drops the keyboard selection and its highlight. Clicking or launching
    /// ends keyboard navigation; leaving the tile behind would suggest the
    /// arrow keys were still somewhere they are not.
    private func clearKeyboardSelection() {
        keyboardSelectionActive = false
        let previous = collectionView.selectionIndexPaths
        collectionView.selectionIndexPaths = []
        for path in previous {
            (collectionView.item(at: path) as? GridCellItem)?.applySelection(false)
        }
    }

    /// Pages by swapping the data source, not by scrolling — see this file's
    /// top-level comment for why the scroll-based version never worked live.
    /// The swap is wrapped in a short directional slide (later page slides in
    /// from the right, mirrored going back) while the collection view stays
    /// opaque, so there is no fade-to-black frame between pages.
    private static let pageSlideOffset: CGFloat = 18
    private var pageTransitionGeneration = 0

    /// Timings for moving between pages, gathered in one place because they
    /// have to move together: the data swap is scheduled off the same
    /// `response` that drives the spring, so changing one alone either shows
    /// the swap mid-flight or leaves the page sitting still after it lands.
    enum PageTransition {
        /// Just short of critically damped. No overshoot: a page that drifts
        /// back at the edge reads as the transition catching.
        static let damping: CGFloat = 0.98

        /// A page leaving, and the same page coming back when a drag is
        /// abandoned.
        static let exitResponse: CGFloat = 0.30
        /// A page arriving. Slightly longer than the exit so the incoming page
        /// settles rather than snapping into place.
        static let entryResponse: CGFloat = 0.36
        /// A trackpad swipe carried far enough to commit.
        static let commitResponse: CGFloat = 0.34

        /// How long to let the spring run before swapping the data source
        /// under it. A critically damped spring has visually arrived after
        /// roughly one `response`; the margin covers the last of the ease.
        static func swapDelay(response: CGFloat) -> TimeInterval {
            TimeInterval(min(max(response * 1.15, 0.12), 0.5))
        }
    }

    private func jumpToPage(_ index: Int) {
        guard model.pages.indices.contains(index), index != currentPage || collectionView.numberOfSections == 0 else { return }
        // Page dots and the arrow keys reach here too, and mid-drag they have
        // the same problem as a swipe — see the swipe wiring in `loadView`.
        guard !itemDrag.isDragging else { return }
        let start = DispatchTime.now()
        pageTransitionGeneration &+= 1
        let generation = pageTransitionGeneration
        prefetchAdjacentPageIcons(including: index)
        collectionView.wantsLayer = true
        collectionView.alphaValue = 1

        let direction: CGFloat = index >= currentPage ? 1 : -1
        let offset = Self.pageSlideOffset

        let layer = collectionView.layer
        let presentationOffset = layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat
        let currentOffset = presentationOffset ?? (layer?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0)
        layer?.removeAnimation(forKey: "pageSlideOut")
        layer?.removeAnimation(forKey: "pageSlideIn")
        let exitTarget = -direction * offset
        let exitSpring = GridSpring.animation(
            keyPath: "transform.translation.x",
            from: currentOffset,
            to: exitTarget,
            damping: PageTransition.damping,
            response: PageTransition.exitResponse
        )
        layer?.add(exitSpring, forKey: "pageSlideOut")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.setValue(exitTarget, forKeyPath: "transform.translation.x")
        CATransaction.commit()

        let settleDelay = PageTransition.swapDelay(response: PageTransition.exitResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            Task { @MainActor in
                guard let self, self.pageTransitionGeneration == generation else { return }

                // Prepare the new page while it is still off the visible
                // side. Keeping the layout settings and reload in this
                // order prevents one frame of the previous icon size.
                self.currentPage = index
                self.layout.settings = self.model.gridSettings
                self.layout.invalidateLayout()
                self.collectionView.collectionViewLayout?.invalidateLayout()
                self.collectionView.reloadData()
                self.collectionView.layoutSubtreeIfNeeded()
                self.collectionView.displayIfNeeded()
                self.collectionView.alphaValue = 1
                self.resetScrollPosition()
                self.pageControl.currentPage = index
                self.prefetchAdjacentPageIcons()

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.collectionView.layer?.removeAllAnimations()
                self.collectionView.layer?.setValue(direction * offset, forKeyPath: "transform.translation.x")
                CATransaction.commit()

                let entrySpring = GridSpring.animation(
                    keyPath: "transform.translation.x",
                    from: direction * offset,
                    to: 0,
                    damping: PageTransition.damping,
                    response: PageTransition.entryResponse
                )
                self.collectionView.layer?.add(entrySpring, forKey: "pageSlideIn")
                self.collectionView.layer?.setValue(0, forKeyPath: "transform.translation.x")
            }
        }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        DiagnosticsLog.launcher.info("page transition: reloadData took \(ms, privacy: .public)ms")
    }

    private func jumpToAdjacentPage(delta: Int) {
        jumpToPage(currentPage + delta)
    }


    /// Fires once a swipe has been confirmed and has cleared the minimum
    /// engage distance (see `GridCollectionView`). Only arms bookkeeping
    /// and the hard fallback timer — the actual neighbor snapshot is
    /// created lazily in `updatePageDrag` once the direction is known.
    private func beginPageDrag() {
        if dragDirection != 0 || dragNeighborView != nil {
            DiagnosticsLog.grid.notice("beginPageDrag: previous drag still settling, finishing it immediately so this swipe isn't dropped")
            finishPageDrag(targetPage: pendingPageDragTargetPage ?? currentPage)
        }
        guard collectionView.bounds.width > 0 else {
            DiagnosticsLog.grid.notice("beginPageDrag: bailed, collectionView.bounds.width <= 0")
            return
        }
        collectionView.wantsLayer = true
        dragHasPrev = currentPage > 0
        dragHasNext = currentPage < model.pages.count - 1
        DiagnosticsLog.grid.notice("beginPageDrag: armed at page \(self.currentPage, privacy: .public), hasPrev=\(self.dragHasPrev, privacy: .public), hasNext=\(self.dragHasNext, privacy: .public)")
        dragGeneration += 1
        let generation = dragGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragSafetyNetTimeout) { [weak self] in
            Task { @MainActor in
                guard let self, self.dragGeneration == generation else { return }
                self.forceResetPageDrag()
            }
        }
    }

    /// Called continuously while the gesture is in progress — `deltaX` is
    /// the *cumulative* horizontal delta since the gesture began, applied
    /// 1:1 to both the live grid's and (once created) the neighbor
    /// snapshot's transform, so both track the fingers exactly. Rubber-
    /// bands (apple-design's resistance formula) when there's no adjacent
    /// page to reveal in that direction.
    private func updatePageDrag(deltaX: CGFloat) {
        let width = max(collectionView.bounds.width, 1)

        if dragDirection == 0 {
            // Direction is now known from the sign of this first real
            // delta — matches the existing convention (negative -> next
            // page, see `GridCollectionView`'s original threshold logic).
            dragDirection = deltaX < 0 ? 1 : -1
            let hasNeighbor = dragDirection > 0 ? dragHasNext : dragHasPrev
            DiagnosticsLog.grid.notice("updatePageDrag: direction resolved to \(self.dragDirection, privacy: .public), hasNeighbor=\(hasNeighbor, privacy: .public)")
            if hasNeighbor, dragNeighborView == nil {
                prefetchAdjacentPageIcons(including: currentPage + dragDirection)
                let start = DispatchTime.now()
                if let neighbor = makeNeighborPageView(forPage: currentPage + dragDirection) {
                    view.addSubview(neighbor, positioned: .above, relativeTo: scrollView)
                    neighbor.layoutSubtreeIfNeeded()
                    dragNeighborView = neighbor
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    DiagnosticsLog.grid.notice("updatePageDrag: neighbor page created for page \(self.currentPage + self.dragDirection, privacy: .public) in \(ms, privacy: .public)ms")
                } else {
                    DiagnosticsLog.grid.notice("updatePageDrag: no neighbor page for page \(self.currentPage + self.dragDirection, privacy: .public)")
                }
            }
        }

        let hasNeighborImage = dragNeighborView != nil
        // An edge pull is a hint, not a second page-sized animation. Using
        // the viewport width as the rubber-band dimension made the terminal
        // page travel far enough to look like a broken page turn.
        let effective: CGFloat
        if hasNeighborImage {
            effective = deltaX
        } else {
            let edgePullLimit: CGFloat = 12
            let resisted = GridSpring.rubberBand(abs(deltaX), dimension: edgePullLimit)
            effective = min(resisted, edgePullLimit) * (deltaX < 0 ? -1 : 1)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        collectionView.layer?.setValue(effective, forKeyPath: "transform.translation.x")
        // The neighbouring page sits over the grid and is kept a page away by
        // its own translation (see `NeighborPage`).
        dragNeighborView?.layer?.setValue(CGFloat(dragDirection) * width + effective, forKeyPath: "transform.translation.x")
        CATransaction.commit()
    }

    private static let pageDragCommitDistance: CGFloat = 20

    private func endPageDrag(deltaX: CGFloat, velocity: CGFloat) {
        let width = max(collectionView.bounds.width, 1)
        let hasNeighbor = dragNeighborView != nil
        let distanceThreshold = Self.pageDragCommitDistance
        let flickVelocityThreshold: CGFloat = 400 // points/sec

        var commit = false
        if hasNeighbor {
            if dragDirection > 0, deltaX <= -distanceThreshold || velocity <= -flickVelocityThreshold {
                commit = true
            } else if dragDirection < 0, deltaX >= distanceThreshold || velocity >= flickVelocityThreshold {
                commit = true
            }
        }

        DiagnosticsLog.grid.notice("endPageDrag: hasNeighbor=\(hasNeighbor, privacy: .public), deltaX=\(deltaX, privacy: .public), velocity=\(velocity, privacy: .public), commit=\(commit, privacy: .public)")

        let targetTranslation: CGFloat = commit ? (dragDirection > 0 ? -width : width) : 0
        let distanceRemaining = targetTranslation - deltaX

        let response = commit ? PageTransition.commitResponse : PageTransition.exitResponse
        let damping = PageTransition.damping
        let boundedVelocity = min(max(velocity, -1600), 1600)
        let relativeVelocity = abs(distanceRemaining) > 1 ? boundedVelocity / distanceRemaining : 0

        let spring = GridSpring.animation(
            keyPath: "transform.translation.x",
            from: deltaX,
            to: targetTranslation,
            damping: damping,
            response: response,
            initialVelocity: relativeVelocity
        )
        collectionView.layer?.add(spring, forKey: "pageDragSettle")
        // The neighbouring page travels the same distance a page away, so it
        // gets the same spring shifted by that page; the relative velocity is
        // unchanged, being a rate over the same distance.
        let neighborOffset = CGFloat(dragDirection) * width
        if let neighborLayer = dragNeighborView?.layer {
            let neighborSpring = GridSpring.animation(
                keyPath: "transform.translation.x",
                from: neighborOffset + deltaX,
                to: neighborOffset + targetTranslation,
                damping: damping,
                response: response,
                initialVelocity: relativeVelocity
            )
            neighborLayer.add(neighborSpring, forKey: "pageDragSettle")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        collectionView.layer?.setValue(targetTranslation, forKeyPath: "transform.translation.x")
        dragNeighborView?.layer?.setValue(neighborOffset + targetTranslation, forKeyPath: "transform.translation.x")
        CATransaction.commit()

        let targetPage = commit ? currentPage + dragDirection : currentPage
        pendingPageDragTargetPage = targetPage
        let generation = dragGeneration
        // Timed off `response`, not `settlingDuration`. The latter is when the
        // spring stops *moving*, which is well past when it has visually
        // arrived — measured 417ms for a page that looked settled in about
        // half that, and the data swap sat waiting for all of it. That wait was
        // the lag: the swap itself takes ~7ms.
        let settleDuration = PageTransition.swapDelay(response: response)
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDuration) { [weak self] in
            Task { @MainActor in
                guard let self, self.dragGeneration == generation else { return }
                self.finishPageDrag(targetPage: targetPage)
            }
        }
    }

    private func finishPageDrag(targetPage: Int) {
        currentPage = targetPage

        collectionView.isHidden = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        collectionView.layer?.removeAllAnimations()
        collectionView.layer?.setValue(0, forKeyPath: "transform.translation.x")
        CATransaction.commit()

        layout.settings = model.gridSettings
        layout.invalidateLayout()
        collectionView.collectionViewLayout?.invalidateLayout()
        collectionView.reloadData()
        collectionView.layoutSubtreeIfNeeded()
        collectionView.displayIfNeeded()
        collectionView.isHidden = false

        resetScrollPosition()
        pageControl.currentPage = currentPage
        dragNeighborView?.removeFromSuperview()
        dragNeighborView = nil
        dragDirection = 0
        pendingPageDragTargetPage = nil
        dragGeneration += 1
        prefetchAdjacentPageIcons()
    }

    private func resetScrollPosition() {
        guard scrollView.contentView.bounds.origin != .zero else { return }
        scrollView.contentView.bounds.origin = .zero
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    public func resetDragStateIfNeeded() {
        guard dragNeighborView != nil || dragDirection != 0 else { return }
        forceResetPageDrag()
    }

    private func forceResetPageDrag() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        collectionView.layer?.removeAllAnimations()
        collectionView.layer?.setValue(0, forKeyPath: "transform.translation.x")
        CATransaction.commit()
        resetScrollPosition()
        dragNeighborView?.removeFromSuperview()
        dragNeighborView = nil
        dragDirection = 0
        pendingPageDragTargetPage = nil
        collectionView.reloadData()
        pageControl.currentPage = currentPage
        dragGeneration += 1
    }

    /// Page `page` as a live grid, laid over the current one for a drag to
    /// move a page away — see `NeighborPage`.
    private func makeNeighborPageView(forPage page: Int) -> NSView? {
        guard model.pages.indices.contains(page) else { return nil }
        let metrics = currentIconLayoutMetrics
        return NeighborPage.makeView(
            items: model.pages[page],
            model: model,
            iconCache: iconCache,
            itemIdentifier: itemIdentifier,
            iconSize: metrics.baseSize,
            visualScale: metrics.visualScale,
            size: collectionView.bounds.size,
            scrollViewFrame: scrollView.frame
        )
    }

    /// Test hook: a neighbouring page exactly as a drag builds it.
    func neighborPageForTesting(page: Int) -> NSView? {
        makeNeighborPageView(forPage: page)
    }

    /// Test hook: starts a page swipe and moves it by `deltaX`, as the
    /// trackpad would, and returns the neighbouring page it brought in. End it
    /// with `resetDragStateIfNeeded()`.
    func pageDragForTesting(deltaX: CGFloat) -> NSView? {
        beginPageDrag()
        updatePageDrag(deltaX: deltaX)
        return dragNeighborView
    }

#if LAUNCHPAD_DEBUG_HOOKS
    public func debugSimulatePageDrag(commit: Bool) {
        guard model.pages.count > 1 else {
            DiagnosticsLog.launcher.info("debugSimulatePageDrag: only \(self.model.pages.count, privacy: .public) page(s), nothing to drag between")
            return
        }
        let startPage = currentPage
        DiagnosticsLog.launcher.info("debugSimulatePageDrag: starting at page \(startPage, privacy: .public), commit=\(commit, privacy: .public)")
        beginPageDrag()
        let width = max(collectionView.bounds.width, 1)
        let commitTargetDeltaX: CGFloat = -width * 0.5
        let abortTargetDeltaX: CGFloat = -8
        let targetDeltaX = commit ? commitTargetDeltaX : abortTargetDeltaX
        let steps = 10
        for step in 1...steps {
            updatePageDrag(deltaX: targetDeltaX * CGFloat(step) / CGFloat(steps))
        }
        endPageDrag(deltaX: targetDeltaX, velocity: commit ? -900 : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                DiagnosticsLog.launcher.info("debugSimulatePageDrag: ended at page \(self.currentPage, privacy: .public) (was \(startPage, privacy: .public))")
            }
        }
    }
    #endif

#if LAUNCHPAD_DEBUG_HOOKS
    public func debugOpenFolder(ordinal: Int) {
        guard model.pages.indices.contains(currentPage) else { return }
        let folderIndices = model.pages[currentPage].indices.filter {
            if case .folder = model.pages[currentPage][$0] { return true }
            return false
        }
        let position = max(ordinal, 1) - 1
        guard folderIndices.indices.contains(position),
              case .folder(let folderID) = model.pages[currentPage][folderIndices[position]] else {
            DiagnosticsLog.launcher.info("debugOpenFolder: page \(self.currentPage, privacy: .public) has \(folderIndices.count, privacy: .public) folder(s), no #\(ordinal, privacy: .public)")
            return
        }
        DiagnosticsLog.launcher.info("debugOpenFolder: opening folder #\(ordinal, privacy: .public) at index \(folderIndices[position], privacy: .public)")
        openFolder(folderID)
    }
    #endif

#if LAUNCHPAD_DEBUG_HOOKS
    public func debugSimulateItemDrag(mode: String) {
        guard model.pages.indices.contains(currentPage), model.pages[currentPage].count > 1,
              let sourceFrame = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame else {
            DiagnosticsLog.grid.notice("debugSimulateItemDrag: not enough items on the current page to drag")
            return
        }
        if mode == "interrupt" {
            debugSimulateInterruptedItemDrag()
            return
        }
        if mode == "pageturn-release" {
            debugSimulatePageTurnRelease()
            return
        }
        if mode == "wheel-during-drag" {
            debugSimulateWheelDuringDrag()
            return
        }
        let targetIndex = mode == "folder" ? 1 : model.pages[currentPage].count - 1
        guard let targetFrame = layout.layoutAttributesForItem(at: IndexPath(item: targetIndex, section: 0))?.frame else { return }
        // "folder" aims dead center (within the ~60% folder-candidate
        // zone); "reorder" aims just inside the trailing edge, outside
        // that zone, so it registers purely as an insertion point.
        let targetPoint = mode == "folder"
            ? NSPoint(x: targetFrame.midX, y: targetFrame.midY)
            : NSPoint(x: targetFrame.maxX - 2, y: targetFrame.midY)

        DiagnosticsLog.grid.notice("debugSimulateItemDrag: mode=\(mode, privacy: .public), source item 0 -> target item \(targetIndex, privacy: .public)")
        let startPoint = NSPoint(x: sourceFrame.midX, y: sourceFrame.midY)

        // Dispatched through window.sendEvent (a *real* AppKit event-
        // routing pass), not by calling handleItemMouseDown/Dragged/Up
        // directly — three prior "fixes" in this exact area all missed
        // real regressions because calling those methods directly bypasses
        // GridCollectionView's own mouseDown/mouseDragged/mouseUp overrides
        // entirely, so it could never have caught a bug in whether real
        // events even reach them (the same blind spot the search-field bug
        // exposed, caught there only via window.sendEvent). This is the
        // first version of this hook that actually exercises that path.
        guard let window = collectionView.window else {
            DiagnosticsLog.grid.notice("debugSimulateItemDrag: no window")
            return
        }
        window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseDown, at: startPoint, in: collectionView))

        let steps = 6
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = NSPoint(x: startPoint.x + (targetPoint.x - startPoint.x) * t, y: startPoint.y + (targetPoint.y - startPoint.y) * t)
            window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseDragged, at: point, in: collectionView))
        }

        // Longer than both the reorder debounce and folder dwell delay, so
        // whichever candidate applies has already committed by the time
        // mouseUp fires — matching a real, deliberate (not flicked) drag.
        DispatchQueue.main.asyncAfter(deadline: .now() + ItemDrag.itemDragFolderHoverDelay + 0.15) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseUp, at: targetPoint, in: self.collectionView))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    Task { @MainActor in
                        let pageCounts = self.model.pages.map(\.count)
                        let folderCount = self.model.folders.count
                        DiagnosticsLog.grid.notice("debugSimulateItemDrag: settled — page counts=\(pageCounts, privacy: .public), folder count=\(folderCount, privacy: .public), activeDrag=\(self.itemDrag.isDragging, privacy: .public)")
                    }
                }
            }
        }
    }
    #endif

#if LAUNCHPAD_DEBUG_HOOKS
    /// Starts an item drag, then asks for a discrete page change the way a
    /// mouse wheel notch does, and logs whether the page moved.
    ///
    /// It must not: a page change from that path never tells the drag session,
    /// so the dragged item's own cell comes back at full opacity and the app
    /// appears twice. Repeats the same call once the drag is over to show the
    /// paging itself still works.
    private func debugSimulateWheelDuringDrag() {
        guard model.pages.count > 1,
              currentPage < model.pages.count - 1,
              model.pages.indices.contains(currentPage),
              !model.pages[currentPage].isEmpty,
              let sourceFrame = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
              let window = collectionView.window else {
            DiagnosticsLog.grid.notice("debugSimulateWheelDuringDrag: needs a next page with items, and a window")
            return
        }
        let startPage = currentPage
        let start = NSPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        // Stays away from both the edge zones and any other icon's centre, so
        // the drag is a plain reorder with no page turn or folder candidate.
        let middle = NSPoint(x: collectionView.bounds.midX, y: sourceFrame.midY)
        window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseDown, at: start, in: collectionView))
        for step in 1...6 {
            let t = CGFloat(step) / 6
            let point = NSPoint(x: start.x + (middle.x - start.x) * t, y: start.y + (middle.y - start.y) * t)
            window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseDragged, at: point, in: collectionView))
        }
        DiagnosticsLog.grid.notice("debugSimulateWheelDuringDrag: dragging=\(self.itemDrag.isDragging, privacy: .public), page=\(self.currentPage, privacy: .public)")
        collectionView.onSwipePage?(1)

        // `jumpToPage` fades out before it swaps the page, so `currentPage`
        // is read after that has had time to happen — reading it straight
        // after the call reports the old page either way and proves nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                DiagnosticsLog.grid.notice("debugSimulateWheelDuringDrag: after a wheel notch mid-drag, page=\(self.currentPage, privacy: .public) (started at \(startPage, privacy: .public)), dragging=\(self.itemDrag.isDragging, privacy: .public)")
                window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseUp, at: middle, in: self.collectionView))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    Task { @MainActor in
                        DiagnosticsLog.grid.notice("debugSimulateWheelDuringDrag: drop settled, dragging=\(self.itemDrag.isDragging, privacy: .public), page=\(self.currentPage, privacy: .public)")
                        self.collectionView.onSwipePage?(1)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            Task { @MainActor in
                                DiagnosticsLog.grid.notice("debugSimulateWheelDuringDrag: same wheel notch with no drag, page=\(self.currentPage, privacy: .public)")
                            }
                        }
                    }
                }
            }
        }
    }
    #endif

#if LAUNCHPAD_DEBUG_HOOKS
    /// Drags to the page edge, waits for the mid-drag page turn to start, then
    /// releases *while it is still sliding* — the window in which the turn's
    /// settle block bails out because the drag is already over.
    ///
    /// Logs the collection view's translation afterwards: anything but 0 means
    /// the grid is parked a page off-screen with nothing but wallpaper
    /// showing, which is exactly the state this hook exists to catch.
    private func debugSimulatePageTurnRelease() {
        guard model.pages.count > 1,
              currentPage < model.pages.count - 1,
              model.pages.indices.contains(currentPage),
              !model.pages[currentPage].isEmpty,
              let sourceFrame = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
              let window = collectionView.window else {
            DiagnosticsLog.grid.notice("debugSimulatePageTurnRelease: needs a next page with items, and a window")
            return
        }
        let startPage = currentPage
        let start = NSPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        // Well inside the trailing edge zone, so the dwell timer arms a turn.
        let edge = NSPoint(x: collectionView.bounds.width - 8, y: sourceFrame.midY)
        let hit = window.contentView?.hitTest(collectionView.convert(start, to: nil))
        DiagnosticsLog.grid.notice("debugSimulatePageTurnRelease: starting at page \(startPage, privacy: .public), grab point hits \(String(describing: hit), privacy: .public)")
        window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseDown, at: start, in: collectionView))
        for step in 1...6 {
            let t = CGFloat(step) / 6
            let point = NSPoint(x: start.x + (edge.x - start.x) * t, y: start.y + (edge.y - start.y) * t)
            window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseDragged, at: point, in: collectionView))
        }

        // Just past the dwell delay: the turn has committed and its spring is
        // still running (response 0.30, so its settle block is a good 0.5s
        // out). Releasing here is the whole point of the hook.
        DispatchQueue.main.asyncAfter(deadline: .now() + ItemDrag.itemDragEdgeHoverDelay + 0.02) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseUp, at: edge, in: self.collectionView))
                DiagnosticsLog.grid.notice("debugSimulatePageTurnRelease: sent mouseUp, activeDrag=\(self.itemDrag.isDragging, privacy: .public), page=\(self.currentPage, privacy: .public), x=\(self.debugCollectionTranslationX, privacy: .public)")
                // Read back before the turn's own settle block would have run:
                // this is the window the bug lived in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    Task { @MainActor in
                        DiagnosticsLog.grid.notice("debugSimulatePageTurnRelease: mid-transition x=\(self.debugCollectionTranslationX, privacy: .public) (width=\(self.collectionView.bounds.width, privacy: .public))")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    Task { @MainActor in
                        DiagnosticsLog.grid.notice("debugSimulatePageTurnRelease: page \(startPage, privacy: .public) -> \(self.currentPage, privacy: .public), final x=\(self.debugCollectionTranslationX, privacy: .public), activeDrag=\(self.itemDrag.isDragging, privacy: .public)")
                    }
                }
            }
        }
    }

    private var debugCollectionTranslationX: CGFloat {
        (collectionView.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat)
            ?? (collectionView.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat)
            ?? 0
    }
    #endif

#if LAUNCHPAD_DEBUG_HOOKS
    private func debugSimulateInterruptedItemDrag() {
        guard model.pages.indices.contains(currentPage), model.pages[currentPage].count > 2,
              let firstFrame = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
              let secondFrame = layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))?.frame,
              let window = collectionView.window else {
            DiagnosticsLog.grid.notice("debugSimulateInterruptedItemDrag: not enough items on the current page, or no window")
            return
        }
        let firstStart = NSPoint(x: firstFrame.midX, y: firstFrame.midY)
        let firstMidDrag = NSPoint(x: firstFrame.midX + 20, y: firstFrame.midY)
        let secondStart = NSPoint(x: secondFrame.midX, y: secondFrame.midY)
        let secondEnd = NSPoint(x: secondFrame.midX + 40, y: secondFrame.midY)

        DiagnosticsLog.grid.notice("debugSimulateInterruptedItemDrag: starting — item 0 drag begins, then item 2 mouseDown interrupts before item 0's mouseUp")

        window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseDown, at: firstStart, in: collectionView))
        window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseDragged, at: firstMidDrag, in: collectionView))
        window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseDragged, at: NSPoint(x: firstMidDrag.x + 10, y: firstMidDrag.y), in: collectionView))

        // No mouseUp here — this is the interruption under test.
        window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseDown, at: secondStart, in: collectionView))

        let steps = 6
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = NSPoint(x: secondStart.x + (secondEnd.x - secondStart.x) * t, y: secondStart.y + (secondEnd.y - secondStart.y) * t)
            window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseDragged, at: point, in: collectionView))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + ItemDrag.itemDragFolderHoverDelay + 0.15) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseUp, at: secondEnd, in: self.collectionView))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    Task { @MainActor in
                        let pageCounts = self.model.pages.map(\.count)
                        DiagnosticsLog.grid.notice("debugSimulateInterruptedItemDrag: settled — page counts=\(pageCounts, privacy: .public), activeDrag=\(self.itemDrag.isDragging, privacy: .public)")
                    }
                }
            }
        }
    }
    #endif

    private static func syntheticMouseEvent(type: NSEvent.EventType, at point: NSPoint, in view: NSView) -> NSEvent {
        let windowPoint = view.convert(point, to: nil)
        return NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0.0 : 1.0
        ) ?? NSEvent()
    }

    private func activate(at indexPath: IndexPath) {
        guard model.pages.indices.contains(currentPage),
              model.pages[currentPage].indices.contains(indexPath.item) else { return }
        let item = model.pages[currentPage][indexPath.item]
        switch item {
        case .app(let id):
            guard let record = model.record(for: id) else { return }
            onLaunch(record)
        case .folder(let folderID):
            openFolder(folderID)
        }
    }

    private func openFolder(_ folderID: FolderID) {
        let metrics = currentIconLayoutMetrics
        // Whatever a previous open left behind, start from visible.
        collectionView.alphaValue = 1
        pageControl.alphaValue = 1
        let host = view.window?.contentView ?? view
        folderOverlay.open(
            folderID,
            in: host,
            metrics: FolderOverlayPresenter.Metrics(
                iconSize: metrics.baseSize * metrics.visualScale,
                configuredColumns: model.gridSettings.columns
            ),
            onLaunch: { [weak self] record in self?.onLaunch(record) },
            onItemDraggedOut: { [weak self] folderPage, folderIndex in
                guard let self else { return }
                self.model.removeFromFolder(
                    folderID,
                    folderPage: folderPage,
                    folderIndex: folderIndex,
                    toPage: self.currentPage
                )
                Task { await self.model.save() }
            },
            onDidClose: { [weak self] in self?.setGridContentHidden(false) }
        )
        setGridContentHidden(true)
    }

    /// Hides the grid while a folder is open, leaving the wallpaper.
    ///
    /// A dimmed but visible grid left the apps behind the panel competing with
    /// the ones inside it. Hiding it outright is what lets the panel be a light
    /// surface instead of needing a near-blackout behind it.
    ///
    /// Uses opacity, not `isHidden`: this project has twice shipped a stuck
    /// `isHidden` that left the grid permanently blank. `openFolder` also resets
    /// it on every open, and the launcher restores it whenever it is shown.
    public func setGridContentHidden(_ hidden: Bool) {
        let target: CGFloat = hidden ? 0 : 1
        guard abs(collectionView.alphaValue - target) > 0.001 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            collectionView.animator().alphaValue = target
            pageControl.animator().alphaValue = target
        }
    }

    private func showWindows(for record: ApplicationRecord, anchorView: NSView) {
        let popover = NSPopover()
        let browserVC = WindowBrowserPopoverController(
            bundleIdentifier: record.bundleIdentifier,
            thumbnailService: windowThumbnailService,
            onDismiss: { [weak popover] in popover?.close() }
        )
        popover.contentViewController = browserVC
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 280)
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
    }

    private func contextMenu(for indexPath: IndexPath) -> NSMenu? {
        guard model.pages.indices.contains(currentPage),
              model.pages[currentPage].indices.contains(indexPath.item) else { return nil }
        let item = model.pages[currentPage][indexPath.item]

        switch item {
        case .folder(let folderID):
            return ContextMenuBuilder.folderMenu(
                open: { [weak self] in self?.openFolder(folderID) },
                rename: { [weak self] in self?.promptRenameFolder(at: indexPath) },
                ungroup: { [weak self] in
                    guard let self else { return }
                    self.model.ungroupFolder(folderID)
                    Task { await self.model.save() }
                },
                iconVisibility: model.menuIconVisibility
            )
        case .app(let id):
            guard let record = model.record(for: id) else { return nil }
            return contextMenu(for: record, anchorView: collectionView.item(at: indexPath)?.view)
        }
    }

    /// The same per-app menu the grid shows, for a record the caller addresses
    /// however it likes. The search results live in their own collection view
    /// and have no grid index path, but the menu they need is identical — so
    /// this is the one definition both surfaces build from.
    ///
    /// `anchorView` is what the window-browser popover attaches to. Without one
    /// the item is left out rather than shown with nowhere to open.
    public func contextMenu(for record: ApplicationRecord, anchorView: NSView?) -> NSMenu {
        var showWindows: (() -> Void)?
        if let anchorView {
            showWindows = { [weak self] in self?.showWindows(for: record, anchorView: anchorView) }
        }
        let actions = ContextMenuBuilder.Actions(
            open: { [weak self] in self?.onLaunch(record) },
            openNewInstance: record.canOpenNewInstance ? { [weak self] in
                self?.model.recordLaunch(for: record.id)
                Task { await self?.model.save() }
                AppLauncher.launch(record, createsNewInstance: true)
            } : nil,
            showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([record.bundleURL]) },
            rename: { [weak self] in self?.promptRenameApp(record: record) },
            hide: { [weak self] in self?.hideApp(record) },
            getInfo: { NSWorkspace.shared.activateFileViewerSelecting([record.bundleURL]) },
            showWindows: showWindows,
            uninstall: { [weak self] in self?.onRequestUninstall(record.bundleIdentifier) }
        )
        return ContextMenuBuilder.menu(for: record, actions: actions, iconVisibility: model.menuIconVisibility)
    }

    private func promptRenameFolder(at indexPath: IndexPath) {
        guard case .folder(let folderID) = model.pages[currentPage][indexPath.item],
              let folder = model.folders[folderID] else { return }
        RenamePrompt.run(currentName: folder.name) { [weak self] newName in
            self?.model.renameFolder(folderID, to: newName)
            Task { await self?.model.save() }
        }
    }

    private func promptRenameApp(record: ApplicationRecord) {
        RenamePrompt.run(currentName: model.displayName(for: record)) { [weak self] newName in
            guard let self else { return }
            self.model.setAlias(newName == record.displayName ? nil : newName, for: record.id)
            Task { await self.model.save() }
        }
    }

    private func hideApp(_ record: ApplicationRecord) {
        model.hideApplication(record.id)
        Task { await model.save() }
    }


    // MARK: Item drag

    /// Built lazily so it can capture the views `loadView` creates. Its
    /// callbacks are the complete list of what the drag needs from here.
    private lazy var itemDrag = ItemDragController(
        model: model,
        layout: layout,
        collectionView: collectionView,
        scrollView: scrollView,
        view: view,
        callbacks: ItemDragController.Callbacks(
            currentPage: { [unowned self] in currentPage },
            commitPageChange: { [unowned self] page in commitPageChangeDuringItemDrag(to: page) },
            prefetchIcons: { [unowned self] page in prefetchAdjacentPageIcons(including: page) },
            neighborPage: { [unowned self] page in makeNeighborPageView(forPage: page) },
            activateItem: { [unowned self] indexPath in activate(at: indexPath) },
            clearKeyboardSelection: { [unowned self] in clearKeyboardSelection() }
        )
    )

    /// Cancels any in-progress item drag, reverting to the original
    /// arrangement. Called when the launcher is shown so a drag left hanging
    /// by a previous session can never carry into the next one.
    public func cancelItemDragIfNeeded() {
        itemDrag.cancelItemDragIfNeeded()
    }

    /// Swaps the grid to `targetPage` mid-drag.
    ///
    /// Kept here, out of `ItemDragController`, because the statement order is
    /// load-bearing and deliberately *not* the same as `finishPageDrag`'s: this
    /// path never hides the collection view and never resets the scroll
    /// position, while that one must do both. Unifying the two has been
    /// specifically avoided — whichever way they were merged, one of them
    /// regressed.
    private func commitPageChangeDuringItemDrag(to targetPage: Int) {
        currentPage = targetPage
        layout.settings = model.gridSettings
        layout.invalidateLayout()
        collectionView.collectionViewLayout?.invalidateLayout()
        collectionView.reloadData()
        collectionView.layoutSubtreeIfNeeded()
        collectionView.displayIfNeeded()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        collectionView.layer?.setValue(0, forKeyPath: "transform.translation.x")
        CATransaction.commit()
        pageControl.currentPage = targetPage
        prefetchAdjacentPageIcons()
    }

    /// The icon geometry for the current grid slot: `baseSize` is the safe
    /// size for the slot, `visualScale` the multiplier the inter-cell gap can
    /// still afford. `GridCellItem` applies the multiplier to the real icon
    /// constraint, so its centered icon+label group and hit region share this
    /// geometry, as do the page snapshots.
    ///
    /// Returned together, not as two properties: every caller needs both, and
    /// two properties meant deriving the same metrics twice per cell.
    public var currentIconLayoutMetrics: (baseSize: Double, visualScale: Double) {
        let cellSize = layout.currentCellSize
        guard cellSize.width > 0, cellSize.height > 0 else { return (96, 1) }

        let labelsVisible = model.gridSettings.labelVisible
        let labelAllowance: CGFloat = labelsVisible ? 23 : 8
        let gap = min(
            CGFloat(model.gridSettings.horizontalSpacing),
            CGFloat(model.gridSettings.verticalSpacing)
        )
        let metrics = GridIconLayoutPolicy.iconMetrics(
            cellSize: cellSize,
            labelAllowance: labelAllowance,
            requestedScale: model.gridSettings.iconScale,
            gap: gap
        )
        return (Double(metrics.baseSize), Double(metrics.visualScale))
    }

    public var currentCellSize: NSSize {
        layout.currentCellSize
    }

    // MARK: NSCollectionViewDataSource
    //
    // Always exactly one section: `model.pages[currentPage]`. See the type's
    // doc comment for why pages are a data-source swap, not a scroll
    // position.

    public func numberOfSections(in collectionView: NSCollectionView) -> Int {
        model.pages.isEmpty ? 0 : 1
    }

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        model.pages.indices.contains(currentPage) ? model.pages[currentPage].count : 0
    }

    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let cell = collectionView.makeItem(withIdentifier: itemIdentifier, for: indexPath) as? GridCellItem,
              model.pages.indices.contains(currentPage),
              model.pages[currentPage].indices.contains(indexPath.item) else {
            return NSCollectionViewItem()
        }
        let isSelected = keyboardSelectionActive && collectionView.selectionIndexPaths.contains(indexPath)
        let metrics = currentIconLayoutMetrics
        let iconSize = metrics.baseSize
        let visualScale = metrics.visualScale
        switch model.pages[currentPage][indexPath.item] {
        case .app(let id):
            guard let record = model.record(for: id) else { return cell }
            let cache = iconCache
            let displayName = model.displayName(for: record)
            let expectedKey = record.iconCacheKey
            if let cachedIcon = cache.cachedIconIfAvailable(for: record) {
                DiagnosticsLog.grid.debug("itemForRepresentedObjectAt: icon cache hit for \(record.bundleIdentifier, privacy: .public)")
                cell.configureAsApp(record: record, icon: cachedIcon, isSelected: isSelected, iconSize: iconSize, visualScale: visualScale, displayName: displayName)
            } else {
                DiagnosticsLog.grid.debug("itemForRepresentedObjectAt: icon cache miss for \(record.bundleIdentifier, privacy: .public), fetching async")
                cell.configureAsApp(record: record, icon: NSImage(), isSelected: isSelected, iconSize: iconSize, visualScale: visualScale, displayName: displayName)
                Task { @MainActor in
                    let icon = await cache.icon(for: record)
                    // The cell may have been recycled for a different record by
                    // the time this fetch completes (reloadData() fires on
                    // every grid-settings Apply and search keystroke) — only
                    // apply if it's still showing what we started fetching for.
                    guard cell.currentRequestKey == expectedKey else { return }
                    cell.configureAsApp(record: record, icon: icon, isSelected: isSelected, iconSize: iconSize, visualScale: visualScale, displayName: displayName)
                }
            }
        case .folder(let folderID):
            let folder = model.folders[folderID]
            let name = folder?.name ?? L10n.defaultFolderName
            let key = "folder:\(folderID.value)"
            let previews: [ApplicationRecord] = folder?.pages.flatMap { $0 }.compactMap { item in
                guard case .app(let id) = item else { return nil }
                return model.record(for: id)
            }.prefix(9).map { $0 } ?? []
            // Peek at whatever's already warm in IconCache so the very
            // first frame isn't all-placeholder for a folder the user has
            // already looked at — real icons for anything not yet cached
            // arrive moments later via the async fetch below.
            let warmIcons = previews.compactMap { iconCache.cachedIconIfAvailable(for: $0) }
            cell.configureAsFolder(name: name, isSelected: isSelected, iconSize: iconSize, visualScale: visualScale, icons: warmIcons, requestKey: key)
            // Every warm icon is already on the tile. Re-fetching them would
            // rebuild the same thumbnail from the same images — and this runs
            // for every folder cell on every `reloadData()`.
            if warmIcons.count < previews.count {
                let cache = iconCache
                Task { @MainActor in
                    var icons: [NSImage] = []
                    for record in previews {
                        icons.append(await cache.icon(for: record))
                    }
                    // Same cell-reuse guard as the app case above — the cell
                    // may have been recycled for a different folder (or an
                    // app) by the time these fetches complete.
                    guard cell.currentRequestKey == key else { return }
                    cell.setFolderIcons(icons)
                }
            }
        }
        return cell
    }

}
