import AppKit
import Catalog
import Diagnostics
import Localization
import Persistence
import WindowBrowser


/// The persistent, folder-aware paged grid (2.2/2.4/2.7): backed by
/// `GridModel`+`PagedGridLayout`, with in-page reorder, folder
/// creation/join/dissolve via drag, and a per-item context menu. This is
/// what `LauncherViewController` shows when there's no active search query;
/// search results still use the flat list from Phase 3.
///
/// Pages are a **data-source swap**, not a scroll position: the
/// `NSCollectionView` always shows exactly one section — `model.pages[currentPage]`
/// — and changing page calls `reloadData()` with the new page's items rather
/// than scrolling a wide horizontal strip. An earlier version tried the
/// "one continuous strip, scroll to the page's x-offset" approach; hands-on
/// testing repeatedly found the page never visibly changed despite the
/// scroll code executing correctly (a real, reproducible AppKit scroll-
/// position quirk that wasn't worth chasing further). The trade-off is that
/// dragging an item directly from one page onto another isn't possible in
/// this model — a real regression the earlier design's docs even called out
/// as being made functional; it's removed here in favor of *guaranteed
/// correctness* for basic page navigation, which is what actually blocked
/// the user.
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
    /// Real, confirmed lifecycle bug: nothing previously retained the
    /// `FolderContentsViewController` created in `openFolder` beyond that
    /// function's own local scope — its `.view` stayed alive (retained by
    /// `backdrop`'s subview list), but the *view controller itself*
    /// deallocated almost immediately after `openFolder` returned, since
    /// `NSView` does not retain its owning `NSViewController` back. A view
    /// whose controller has already been deallocated while the view is
    /// still on screen is an invalid, undefined-behavior state for AppKit
    /// (view controller lifecycle/appearance callbacks, `preferredContentSize`
    /// bookkeeping, and this controller's own async icon-loading `Task`
    /// blocks — which capture `[weak self]` pointing at itself — all assume
    /// the controller outlives its view). Retaining it here for as long as
    /// the overlay is shown is the correct, necessary fix regardless of any
    /// single symptom it happens to explain.
    private lazy var folderOverlay = FolderOverlayPresenter(model: model, iconCache: iconCache)
    private let windowThumbnailService = WindowThumbnailService()

    // MARK: Drag-tracked page paging state (see `beginPageDrag`)
    //
    // Deliberately minimal: unlike the reverted first attempt, there is no
    // "hide the live grid, show 3 snapshots" overlay. The live
    // `collectionView` is transformed directly and is NEVER hidden, so a
    // stuck drag state can visually shift it at worst — it can't make
    // content disappear the way the reverted version could.

    /// Only the one snapshot actually needed (whichever neighbor the drag
    /// direction reveals), created lazily once direction is known — not
    /// pre-rendered for both sides up front.
    private var dragNeighborImageView: NSImageView?
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
        // The floating item-drag preview (`createFloatingDragView`) is added
        // directly as this view's child. Every other place in this file that
        // continuously mutates a CALayer transform either sets `wantsLayer`
        // on that exact view first or pairs the write with an active
        // `CAAnimation` — `updateItemDrag`'s per-frame position update does
        // neither, relying instead on the floating view's ancestor chain
        // being part of one coherent, layer-backed compositing tree from the
        // root down. Without this, the floating view's one-shot "lift"
        // animation (added once, auto-removed after ~0.2s) was the only
        // thing keeping it under active compositing — once that settled,
        // later bare `transform.translation` writes stopped reliably
        // recompositing to screen (real, confirmed regression: "the grabbed
        // icon doesn't move from its spot").
        root.wantsLayer = true

        layout.settings = model.gridSettings
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(GridCellItem.self, forItemWithIdentifier: itemIdentifier)
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.menuProvider = { [weak self] indexPath in self?.contextMenu(for: indexPath) }
        collectionView.onSwipePage = { [weak self] delta in self?.jumpToAdjacentPage(delta: delta) }
        collectionView.onSwipeBegan = { [weak self] in self?.beginPageDrag() }
        collectionView.onSwipeChanged = { [weak self] delta in self?.updatePageDrag(deltaX: delta) }
        collectionView.onSwipeEnded = { [weak self] delta, velocity in self?.endPageDrag(deltaX: delta, velocity: velocity) }
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
        // Real, confirmed regression ("ページを変えるとアプリが下に下がる
        // ...ずっと下がったまま...スワイプだけ"): user-confirmed that the
        // shift is a real, *permanent* downward displacement, only via
        // trackpad swipe (never dot/chevron clicks) — which this session
        // couldn't reproduce directly, since simulating a swipe requires
        // Accessibility/GUI-scripting permission this session doesn't have,
        // and the existing `debugSimulatePageDrag` hook calls
        // `beginPageDrag`/`updatePageDrag`/`endPageDrag` directly, bypassing
        // `GridCollectionView.scrollWheel` (and its axis detection/momentum-
        // phase handling) entirely — it can't exercise the one code path
        // implicated. `hasVerticalScroller = false` above only hides the
        // scroll *indicator*; it does not disable scrolling or elastic
        // rubber-band bounce, both of which are otherwise allowed by
        // default on both axes. This view has no scrollable content of its
        // own at all (every page fits its viewport exactly — see
        // `GridCollectionView.scrollWheel`'s own doc comment), so there is
        // no legitimate reason for any elastic movement here, vertical or
        // horizontal, regardless of whether it's proven to be the exact
        // mechanism — disabling both removes an entire class of "some
        // scroll-wheel-adjacent event reaches the scroll view's own
        // elasticity machinery and leaves a residual offset" bugs outright.
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

    /// Pushes the settled icon geometry onto cells that were built before it
    /// was known.
    ///
    /// `itemForRepresentedObjectAt` reads `currentIconSize` once, when the cell
    /// is created, and nothing revisits that afterwards — a cell keeps its
    /// creation-time size until `reloadData()` builds a replacement. The first
    /// layout pass runs before `updatePageControlBottomMargin` has measured the
    /// Dock, so those first cells are sized against a taller cell than the grid
    /// ends up with.
    ///
    /// Reported bug ("初回起動時にアプリが一瞬だけ大きくなってから元のサイズに
    /// 戻る"): on a cold start the reload that would have fixed them is the full
    /// catalog scan finishing a second or two later, so the icons sat visibly
    /// oversized on screen until then and then snapped down. Warm opens never
    /// showed it because their cells already existed at the settled size.
    private func refreshVisibleIconSizes() {
        let cellSize = layout.currentCellSize
        guard cellSize.width > 0, cellSize.height > 0 else { return }
        let iconSize = currentIconSize
        let visualScale = currentEffectiveIconScale
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

    /// The launcher deliberately owns the full target screen so that its
    /// background reaches behind the menu bar. Its interactive grid therefore
    /// has to reserve a bottom safe area itself whenever the real Dock remains
    /// visible.
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

    /// Warms `IconCache` for the pages adjacent to `currentPage`, ahead of
    /// time. Real user report: icons visibly "popped in" a few seconds
    /// after switching pages — `itemForRepresentedObjectAt:` only starts
    /// fetching an icon once its cell is actually about to be displayed,
    /// so a page nobody has looked at yet starts every cell blank. This
    /// also matters for the live drag-neighbor snapshot
    /// (`renderPageSnapshot`), which can only use `cachedIconIfAvailable`
    /// — a synchronous peek that returns blank for anything not already in
    /// memory — so keeping the pages a swipe is likely to reveal warmed
    /// *before* the swipe even starts is what actually makes that snapshot
    /// show real icons instead of placeholders, matching the user's other
    /// ask ("right before a swipe reveals it, have it ready").
    ///
    /// Called whenever `currentPage` changes (here, `jumpToPage`,
    /// `finishPageDrag`) and once on initial load (via `reload()`, already
    /// invoked after the first catalog reconcile). Fire-and-forget: results
    /// land in `IconCache`'s memory dict as a side effect, nothing here
    /// needs to consume them directly.
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

    // MARK: Keyboard navigation (forwarded from LauncherViewController)
    /// A mouse click tracks `collectionView.selectionIndexPaths` (needed for
    /// drag/launch/context-menu targeting) but must NOT draw the visible
    /// highlight ring — a real user found the box+glow that appeared around
    /// every clicked icon distracting ("アプリをいじった時に出る白い枠は基本
    /// 的に出ないように"). Keyboard arrow-key browsing (`moveSelection`/
    /// `select`) is the one case that should still show it, since without
    /// any visual feedback there'd be no way to see where keyboard focus is.
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
        collectionView.selectionIndexPaths = [indexPath]
        collectionView.reloadItems(at: [indexPath])
    }

    /// The data-source-swap approach itself (as opposed to scroll-position
    /// paging) is unchanged and stays that way — see this file's top-level
    /// doc comment for why the earlier scroll-based version never reliably
    /// worked live. The swap is wrapped in a short directional slide while
    /// the collection view stays fully opaque, so there is no fade-to-black
    /// frame between pages.
    /// Adds a small directional slide —
    /// apple-design's "spatial consistency"/"hint in the direction of the
    /// gesture" guidance: a jump to a *later* page slides content out to
    /// the left and the new page in from the right (mirrored for a jump
    /// backward), instead of the fade alone just cutting in place. Still a
    /// discrete jump (not a continuously finger-tracked scroll — that
    /// approach was already tried and abandoned, see this type's top-level
    /// doc comment). Keep the travel deliberately small: the page drag path
    /// provides the large spatial movement; arrow/dot jumps only need a
    /// restrained directional cue.
    private static let pageSlideOffset: CGFloat = 18
    private var pageTransitionGeneration = 0

    private func jumpToPage(_ index: Int) {
        guard model.pages.indices.contains(index), index != currentPage || collectionView.numberOfSections == 0 else { return }
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
            damping: 0.98,
            response: 0.22
        )
        layer?.add(exitSpring, forKey: "pageSlideOut")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.setValue(exitTarget, forKeyPath: "transform.translation.x")
        CATransaction.commit()

        let settleDelay = min(max(exitSpring.settlingDuration, 0.12), 0.42)
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
                    damping: 0.98,
                    response: 0.26
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

    // MARK: Drag-tracked page paging (real-time finger-following swipe), v2
    //
    // First attempt (reverted): hid the live `collectionView` and overlaid
    // 3 pre-rendered snapshots (prev/current/next). Failed on real hardware
    // — the overlay engaged on essentially any trackpad touch (no minimum
    // distance gate) and, if the settle path didn't complete for any
    // reason, `collectionView.isHidden` never reverted to `false`,
    // permanently blanking the grid (confirmed via screenshot, required a
    // force-quit). This version is structurally different, not just
    // tuned differently:
    //  1. `GridCollectionView` now requires the cumulative delta to clear
    //     `minimumEngageDistance` before engaging at all (see that type).
    //  2. The live `collectionView` is never hidden — its own layer is
    //     transformed directly, and only the *one* neighbor page actually
    //     being revealed gets a lazily-created snapshot placed beside it.
    //     Worst case if something goes wrong: a transform offset or a
    //     stray image, never a blank grid.
    //  3. A hard, fixed-duration (`dragSafetyNetTimeout`) fallback timer —
    //     independent of `CASpringAnimation.settlingDuration`, which is what
    //     silently misbehaved before — force-resets everything no matter
    //     what. This is armed from the *start* of the drag, not from its
    //     end, so it must be far longer than any real gesture takes: a
    //     confirmed real bug (not hypothetical) had this at a flat 1s,
    //     which fired *while the user was still mid-drag* on anything
    //     slower than a quick flick — exactly the "look at the next page
    //     before committing" use this feature exists for — silently
    //     force-resetting the neighbor snapshot and transform out from
    //     under still-active fingers. 30s keeps the same last-resort
    //     recovery guarantee without ever tripping during real use.
    //  4. `resetDragStateIfNeeded()` is called every time the launcher
    //     shows (see `LauncherWindowController.show()`), so even if a prior
    //     session somehow left this mid-drag, the next open starts clean.
    // Given the two prior failures in this exact area, this still needs
    // the user's own hands-on trackpad verification — these safeguards
    // change what happens if something goes wrong, not whether the gesture
    // *feels* right, which can't be tested without Accessibility permission.

    /// Fires once a swipe has been confirmed and has cleared the minimum
    /// engage distance (see `GridCollectionView`). Only arms bookkeeping
    /// and the hard fallback timer — the actual neighbor snapshot is
    /// created lazily in `updatePageDrag` once the direction is known.
    private func beginPageDrag() {
        if dragDirection != 0 || dragNeighborImageView != nil {
            // Real, confirmed bug ("連続でページをスワイプした時にページ
            // が送られない時がある"): a previous swipe's settle spring can
            // take up to ~1s to finish (see `endPageDrag`'s commit-case
            // response), and silently bailing here meant a new swipe that
            // began during that window did *nothing at all* — not queued,
            // not deferred, just dropped, with no visible feedback. Instead
            // of bailing, complete the pending transition immediately
            // (landing on whatever page it already committed to, via
            // `pendingPageDragTargetPage` — falling back to `currentPage`
            // only defensively, since a real in-flight drag always sets
            // it) so the new swipe can begin right away rather than being
            // swallowed. This only skips the tail of the previous
            // transition's visual settle, never the transition itself.
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
            if hasNeighbor, dragNeighborImageView == nil {
                prefetchAdjacentPageIcons(including: currentPage + dragDirection)
                if let image = renderPageSnapshot(forPage: currentPage + dragDirection, size: collectionView.bounds.size) {
                    let imageView = PageSnapshotRenderer.makeNeighborImageView(
                        image: image,
                        direction: dragDirection,
                        pageWidth: width,
                        scrollViewFrame: scrollView.frame
                    )
                    view.addSubview(imageView, positioned: .above, relativeTo: scrollView)
                    dragNeighborImageView = imageView
                    DiagnosticsLog.grid.notice("updatePageDrag: neighbor snapshot created for page \(self.currentPage + self.dragDirection, privacy: .public)")
                } else {
                    DiagnosticsLog.grid.notice("updatePageDrag: renderPageSnapshot returned nil for page \(self.currentPage + self.dragDirection, privacy: .public)")
                }
            }
        }

        let hasNeighborImage = dragNeighborImageView != nil
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
        dragNeighborImageView?.layer?.setValue(effective, forKeyPath: "transform.translation.x")
        CATransaction.commit()
    }

    /// Decides the destination page from the final position and estimated
    /// release velocity (a sufficiently fast flick commits even short of
    /// the distance threshold — apple-design's momentum projection), then
    /// springs the rest of the way with the release velocity handed off
    /// (not hard-cut) before swapping in the real page content. The actual
    /// cleanup (`finishPageDrag`) is scheduled off the spring's own
    /// settling duration for visual accuracy, but `beginPageDrag`'s fixed
    /// `dragSafetyNetTimeout` fallback is the real safety net if that
    /// duration ever misbehaves.
    /// Round 13 §G: fixed, not width-relative — "even the slightest
    /// deliberate swipe" should commit regardless of screen size/column
    /// count, and a fixed point value reads as more predictable/tunable
    /// than a width fraction that changes with icon size. Real, confirmed
    /// report ("ページ送りの感度が下がってる、少しでもスワイプしたら動く
    /// ように"): 48pt required a noticeably deliberate swipe. Lowered to
    /// 20pt — still comfortably above `GridCollectionView
    /// .minimumEngageDistance` (10pt — the separate, unrelated gate for
    /// "does this even count as a horizontal gesture at all," checked
    /// before this function is ever reached), leaving a little room for a
    /// deliberate reversal to still land under the commit line, but small
    /// enough that a light swipe commits instead of springing back.
    /// `deltaX`/`velocity` here are already the gesture's *final* values at
    /// release (not a stored peak), so reversing an in-progress swipe back
    /// toward the original page already reads as a cancel for free — no
    /// separate "was this reversed" logic is needed.
    private static let pageDragCommitDistance: CGFloat = 20

    private func endPageDrag(deltaX: CGFloat, velocity: CGFloat) {
        let width = max(collectionView.bounds.width, 1)
        let hasNeighbor = dragNeighborImageView != nil
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

        // Keep the same restrained spring for click and swipe paths. The
        // old 0.86/0.45 commit spring produced a visible overshoot at the
        // page edge and made a normal swipe feel like a second gesture.
        let (damping, response): (CGFloat, CGFloat) = commit ? (0.97, 0.30) : (1.0, 0.24)
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
        dragNeighborImageView?.layer?.add(spring, forKey: "pageDragSettle")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        collectionView.layer?.setValue(targetTranslation, forKeyPath: "transform.translation.x")
        dragNeighborImageView?.layer?.setValue(targetTranslation, forKeyPath: "transform.translation.x")
        CATransaction.commit()

        let targetPage = commit ? currentPage + dragDirection : currentPage
        pendingPageDragTargetPage = targetPage
        let generation = dragGeneration
        // The safety-net timer is still the failure recovery; this bound only
        // keeps a pathological spring from delaying the data-source swap.
        let settleDuration = min(max(spring.settlingDuration, 0), 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDuration) { [weak self] in
            Task { @MainActor in
                guard let self, self.dragGeneration == generation else { return }
                self.finishPageDrag(targetPage: targetPage)
            }
        }
    }

    /// Real, confirmed bug (user report: "the previous app flashes right at
    /// the switch"): this used to reset `collectionView`'s transform to 0
    /// — bringing it into the visible position — *before* calling
    /// `reloadData()`. Between that transform reset and `reloadData()`'s
    /// cells actually being laid out, `collectionView` sat on-screen still
    /// showing the *old* page's content, and removing the neighbor snapshot
    /// (which was covering it with the correct new-page image) right after
    /// exposed that stale frame for however long AppKit took to catch up —
    /// a real, visible flash of the previous page.
    ///
    /// Fixed by doing everything data-related while `collectionView` is
    /// still off-screen (at whatever transform `endPageDrag`'s spring left
    /// it at, e.g. ±width): reload, force the layout *and* the actual
    /// on-screen redraw to complete synchronously, and only *then* bring it
    /// on-screen (transform reset to 0) and remove the neighbor overlay. By
    /// the time either of those becomes visible, the live view already
    /// shows the correct content — nothing stale to flash.
    private func finishPageDrag(targetPage: Int) {
        currentPage = targetPage

        // A large-scale parallel code audit (7 independent finders) traced
        // a real, confirmed bug ("ページを変えるとアプリが下に下がる...
        // スワイプだけ...数百msくらいで下に行く") to this exact spot:
        // `jumpToPage` (dot/chevron clicks, which NEVER reproduce the
        // symptom) never forces a synchronous layout/redraw pass at all —
        // it just calls `reloadData()` and lets AppKit's normal deferred
        // layout cycle handle it. This function used to be the one place
        // in the whole file that called `layoutSubtreeIfNeeded()`/
        // `displayIfNeeded()` while `collectionView`'s own layer transform
        // was still non-identity (off-screen, ±width from the drag).
        // Multiple independent auditors flagged that exact combination as
        // the only structural difference between the two page-change
        // paths, and traced it (via `PagedGridLayout.prepare()`'s own
        // self-referential `contentSize` computation, fixed separately in
        // `PagedGridLayout.swift`) to the long-documented ~63pt "content
        // taller than viewport" overflow this function's own
        // `resetScrollPosition()` doc comment records.
        //
        // Fix: reset the transform to identity *before* reloading/forcing
        // layout, not after. The first version of this fix assumed
        // `dragNeighborImageView` — positioned `.above` `scrollView`, see
        // `updatePageDrag` — fully covered `collectionView` at this point,
        // making the early on-screen transform invisible. Real, confirmed
        // regression from that assumption (user report: "前のページの
        // アプリ名の文字が一瞬残って既存の文字と重なる"): the snapshot's
        // host collection view renders with a transparent background
        // (`SnapshotDataSource`'s `tempCollectionView.backgroundColors =
        // [.clear]`, see `renderPageSnapshot`), so only the icon/label
        // *shapes* are opaque — the gaps between/around cells are see-
        // through. With `collectionView` moved on-screen but not yet
        // reloaded for the new page, its stale (previous-page) labels
        // bled through those transparent gaps for one frame, doubling up
        // visibly with the snapshot's own labels. `isHidden` guarantees
        // nothing is drawn at all regardless of what's underneath or how
        // transparent the covering snapshot is — strictly safer than
        // relying on the snapshot's opacity.
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
        dragNeighborImageView?.removeFromSuperview()
        dragNeighborImageView = nil
        dragDirection = 0
        pendingPageDragTargetPage = nil
        dragGeneration += 1
        prefetchAdjacentPageIcons()
    }

    /// Real, confirmed regression ("ページを変えるとアプリが下に下がる...
    /// ずっと下がったまま...スワイプだけ...数百msくらいで下に行く"): a
    /// real, measured fact (via a temporary diagnostic, since a real
    /// trackpad swipe can't be simulated in this session) is that
    /// `collectionView`'s content is actually ~63pt *taller* than
    /// `scrollView`'s visible viewport for this grid's configuration —
    /// contradicting `GridCollectionView.scrollWheel`'s own doc comment
    /// ("a page fits entirely in the viewport... nothing to actually
    /// scroll"), which is evidently not true for every grid configuration.
    /// That 63pt is a *real*, legitimate scrollable range, so if a real
    /// 2-finger trackpad gesture's vertical component ever causes the
    /// enclosing `NSScrollView`/`NSClipView` to scroll even partway into
    /// it (through some path independent of `GridCollectionView`'s own
    /// `scrollWheel` override, which never forwards to `super` and — per
    /// direct code reading — shouldn't be able to cause this on its own),
    /// nothing previously reset it back — only the layer's *transform* was
    /// ever zeroed after a page change, never the scroll view's actual
    /// `contentView.bounds.origin`, a completely independent property. That
    /// would explain every reported detail: permanent (nothing undoes it),
    /// swipe-only (dot/chevron clicks never touch the scroll view at all),
    /// and only becoming visible after the settle delay (this method is
    /// what fires at that point). Forcing it back to `.zero` on every page
    /// change closes off this entire class of drift regardless of the
    /// exact mechanism that first nudges it.
    private func resetScrollPosition() {
        guard scrollView.contentView.bounds.origin != .zero else { return }
        scrollView.contentView.bounds.origin = .zero
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Hard safety net, reachable from three independent places (the fixed
    /// safety-net fallback timer (30s), a background click during a drag, and every time
    /// the launcher shows) — forces the grid back to a normal, fully-
    /// visible state no matter what state the drag machinery is in. Safe
    /// to call even when no drag is active (idempotent no-op beyond a
    /// harmless transform reset and reload).
    public func resetDragStateIfNeeded() {
        guard dragNeighborImageView != nil || dragDirection != 0 else { return }
        forceResetPageDrag()
    }

    private func forceResetPageDrag() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        collectionView.layer?.removeAllAnimations()
        collectionView.layer?.setValue(0, forKeyPath: "transform.translation.x")
        CATransaction.commit()
        resetScrollPosition()
        dragNeighborImageView?.removeFromSuperview()
        dragNeighborImageView = nil
        dragDirection = 0
        pendingPageDragTargetPage = nil
        collectionView.reloadData()
        pageControl.currentPage = currentPage
        dragGeneration += 1
    }

    /// Binds the controller's current geometry to `PageSnapshotRenderer`, which
    /// holds the rendering itself (and the offscreen host window it needs).
    private func renderPageSnapshot(forPage page: Int, size: NSSize) -> NSImage? {
        guard model.pages.indices.contains(page) else { return nil }
        return PageSnapshotRenderer.render(
            items: model.pages[page],
            model: model,
            iconCache: iconCache,
            itemIdentifier: itemIdentifier,
            iconSize: currentIconSize,
            visualScale: currentEffectiveIconScale,
            size: size
        )
    }

    /// Debug-only — this session has no Accessibility/GUI-scripting
    /// permission, so a real trackpad gesture can't be simulated to verify
    /// `beginPageDrag`/`updatePageDrag`/`endPageDrag` end-to-end. This drives
    /// the exact same production methods with synthetic input so at least
    /// the state-machine transition (current page -> next page, no crash)
    /// can be confirmed via `log stream` — not a substitute for real
    /// hands-on trackpad verification, which the drag's actual visual feel
    /// still needs. `commit: true` simulates a fast flick past the commit
    /// threshold; `commit: false` simulates a short drag that springs back
    /// to the current page — both paths matter given this feature's history.
    public func debugSimulatePageDrag(commit: Bool) {
        guard model.pages.count > 1 else {
            DiagnosticsLog.launcher.info("debugSimulatePageDrag: only \(self.model.pages.count, privacy: .public) page(s), nothing to drag between")
            return
        }
        let startPage = currentPage
        DiagnosticsLog.launcher.info("debugSimulatePageDrag: starting at page \(startPage, privacy: .public), commit=\(commit, privacy: .public)")
        beginPageDrag()
        let width = max(collectionView.bounds.width, 1)
        // Round 13 §G (revised): `endPageDrag`'s commit threshold is now a
        // fixed 20pt (lowered further from 48pt per a real report that the
        // swipe felt insensitive) — the abort case must stay a small fixed
        // delta clearly *below* that threshold regardless of screen width,
        // small enough not to collide with the new lower commit line. The
        // commit case can stay width-relative since half the page width
        // always clears 20pt.
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

    /// Debug-only (`LAUNCHPAD_DEBUG_OPEN_FIRST_FOLDER`, wired in
    /// `AppDelegate`) — opens the first folder found on the current page,
    /// exercising the exact same `openFolder` path a real click on a
    /// folder icon takes (`activate(at:)` calls it directly; this just
    /// skips finding the folder via a real click). Verifies the new
    /// full-screen overlay's view hierarchy/constraints/animation build
    /// without crashing — real click-to-dismiss-on-backdrop and drag-out-
    /// of-folder still need the user's own hands-on confirmation, since
    /// those depend on real event delivery this session can't fully drive.
    /// - Parameter ordinal: which folder on the current page to open, 1-based.
    ///   Folder panels size themselves from their item count, so checking the
    ///   layout at all means being able to reach a folder with a given number
    ///   of items rather than only whichever one happens to come first.
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

    /// Debug-only — this session has no Accessibility/GUI-scripting
    /// permission, so a real mouse-down/drag/mouse-up on an icon can't be
    /// performed to verify the item-drag state machine end-to-end. Drives
    /// the real `handleItemMouseDown`/`handleItemMouseDragged`/
    /// `handleItemMouseUp` methods with synthetic points (bypassing only
    /// the `NSEvent`/`sendEvent` layer, not the state machine itself), so
    /// the reorder/folder-creation outcome and absence of a crash can be
    /// confirmed via `log stream`. `mode: "folder"` drags item 0 onto item
    /// 1's center (past the folder dwell delay); `mode: "reorder"` drags
    /// item 0 toward the end of the page.
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

    /// Reproduces the exact interleaving caught live via `log stream`
    /// during real user testing: a fresh mouseDown on item 2 arrives while
    /// item 0's drag is still active, with NO mouseUp for item 0 in
    /// between. Before the `handleItemMouseDown` fix, every subsequent
    /// mouseDragged kept updating item 0's stale session (checked first in
    /// `handleItemMouseDragged`) instead of starting a fresh one for item
    /// 2 — matching the report "after one drag breaks, dragging a
    /// different app moves the first app instead."
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

    /// - Parameter hostView: the reference's own `FolderOverlay` is a
    ///   full-screen `ZStack` sibling covering the *entire* launcher (search
    ///   bar included) — not scoped to just the grid area. `GridViewController
    ///   .view` itself is only the bottom ~954pt of the 1050pt-tall window (the
    ///   search bar occupies the top ~96pt as a sibling within
    ///   `LauncherViewController.view`), so anchoring the backdrop to `view`
    ///   left the search bar strip completely undimmed/unblurred while a folder
    ///   was open — a real, confirmed visual bug ("上の部分がおかしい": the
    ///   search bar area read as a bright, untouched strip floating above the
    ///   darkened grid instead of being part of the same full-screen overlay).
    ///   `view.window?.contentView` is the window's actual full-bounds root view
    ///   (see `LauncherWindowController.makeWindow`'s own `root`), so anchoring
    ///   there instead covers the whole screen, exactly like the reference.
    private func openFolder(_ folderID: FolderID) {
        // Whatever a previous open left behind, start from visible.
        collectionView.alphaValue = 1
        pageControl.alphaValue = 1
        let host = view.window?.contentView ?? view
        folderOverlay.open(
            folderID,
            in: host,
            metrics: FolderOverlayPresenter.Metrics(
                iconSize: currentIconSize * currentEffectiveIconScale,
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

    /// Hides the grid itself while a folder is open, leaving the wallpaper.
    ///
    /// An opened folder used to sit over a dimmed but still-visible grid, which
    /// left the apps behind the panel legible through it and competing with the
    /// ones inside it. Hiding the grid outright is what the reference launcher
    /// does, and it is what lets the panel be a light surface rather than
    /// needing a near-blackout behind it to separate from its own background.
    ///
    /// Uses opacity rather than `isHidden`: this project has twice shipped a
    /// stuck `isHidden` that left the grid permanently blank and needed a
    /// force-quit. Alongside that, `openFolder` sets this false again on every
    /// open and `LauncherViewController` restores it whenever the launcher is
    /// shown, so a state left behind by one path cannot outlive it.
    public func setGridContentHidden(_ hidden: Bool) {
        let target: CGFloat = hidden ? 0 : 1
        guard abs(collectionView.alphaValue - target) > 0.001 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            collectionView.animator().alphaValue = target
            pageControl.animator().alphaValue = target
        }
    }

    private func showWindows(for record: ApplicationRecord, anchorIndexPath: IndexPath) {
        guard let cell = collectionView.item(at: anchorIndexPath) else { return }
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
        popover.show(relativeTo: cell.view.bounds, of: cell.view, preferredEdge: .maxY)
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
                }
            )
        case .app(let id):
            guard let record = model.record(for: id) else { return nil }
            let actions = ContextMenuBuilder.Actions(
                open: { [weak self] in self?.onLaunch(record) },
                openNewInstance: record.canOpenNewInstance ? { [weak self] in
                    self?.model.recordLaunch(for: record.id)
                    Task { await self?.model.save() }
                    AppLauncher.launch(record, createsNewInstance: true)
                } : nil,
                showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([record.bundleURL]) },
                rename: { [weak self] in self?.promptRenameApp(at: indexPath, record: record) },
                hide: { [weak self] in self?.hideApp(record) },
                removeFromFolder: nil,
                getInfo: { NSWorkspace.shared.activateFileViewerSelecting([record.bundleURL]) },
                showWindows: { [weak self] in self?.showWindows(for: record, anchorIndexPath: indexPath) },
                uninstall: { [weak self] in self?.onRequestUninstall(record.bundleIdentifier) }
            )
            return ContextMenuBuilder.menu(for: record, isInFolder: false, actions: actions)
        }
    }

    private func promptRenameFolder(at indexPath: IndexPath) {
        guard case .folder(let folderID) = model.pages[currentPage][indexPath.item],
              let folder = model.folders[folderID] else { return }
        presentRenameAlert(currentName: folder.name) { [weak self] newName in
            self?.model.renameFolder(folderID, to: newName)
            Task { await self?.model.save() }
        }
    }

    private func promptRenameApp(at indexPath: IndexPath, record: ApplicationRecord) {
        presentRenameAlert(currentName: model.displayName(for: record)) { [weak self] newName in
            guard let self else { return }
            self.model.setAlias(newName == record.displayName ? nil : newName, for: record.id)
            Task { await self.model.save() }
        }
    }

    private func hideApp(_ record: ApplicationRecord) {
        model.hideApplication(record.id)
        Task { await model.save() }
    }

    private func presentRenameAlert(currentName: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = L10n.renameAlertTitle
        let field = NSTextField(string: currentName)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.renameConfirmButton)
        alert.addButton(withTitle: L10n.cancelButton)
        if alert.runModal() == .alertFirstButtonReturn {
            completion(field.stringValue)
        }
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
            pageSnapshot: { [unowned self] page, size in renderPageSnapshot(forPage: page, size: size) },
            activateItem: { [unowned self] indexPath in activate(at: indexPath) },
            clearKeyboardSelection: { [unowned self] in keyboardSelectionActive = false }
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

    /// The safe base size for an icon in the current grid slot. The effective
    /// multiplier is applied by `GridCellItem` to the real icon constraint, so
    /// its centered icon+label group and hit region use the same geometry.
    public var currentIconSize: Double {
        let cellSize = layout.currentCellSize
        guard cellSize.width > 0, cellSize.height > 0 else { return 96 }

        let labelsVisible = model.gridSettings.labelVisible
        let labelAllowance: CGFloat = labelsVisible ? 23 : 8
        return Double(GridIconLayoutPolicy.safeSlot(cellSize: cellSize, labelAllowance: labelAllowance))
    }

    /// The effective visual multiplier after the current inter-cell gap has
    /// supplied its safe expansion budget. The budget is intentionally
    /// derived here, beside `currentIconSize`, so every cell and snapshot uses
    /// the same value without changing `PagedGridLayout` or Settings APIs.
    public var currentEffectiveIconScale: Double {
        let cellSize = layout.currentCellSize
        guard cellSize.width > 0, cellSize.height > 0 else { return 1 }

        let labelsVisible = model.gridSettings.labelVisible
        let labelAllowance: CGFloat = labelsVisible ? 23 : 8
        let safeSlot = GridIconLayoutPolicy.safeSlot(cellSize: cellSize, labelAllowance: labelAllowance)
        let gap = min(
            CGFloat(model.gridSettings.horizontalSpacing),
            CGFloat(model.gridSettings.verticalSpacing)
        )
        return Double(GridIconLayoutPolicy.effectiveVisualScale(
            requestedScale: model.gridSettings.iconScale,
            safeSlot: safeSlot,
            gap: gap
        ))
    }

    /// The grid's actual per-cell size right now (`PagedGridLayout`'s
    /// computed `columns x rows` slot, not a fixed constant). Exposed for
    /// the same reason as `currentIconSize`: search results previously used
    /// their own hardcoded cell size/spacing/margins, which meant flipping
    /// between the grid and search changed not just icon size but the whole
    /// arrangement (column count, gaps, edge margins) — a second, related
    /// user report ("レイアウトも合わない") after the icon-size-only fix.
    /// Reusing the grid's real cell size (plus its actual spacing/margins,
    /// read directly from `GridSettings` by the caller) makes the two views
    /// share one visual grid, not two independently-tuned ones.
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
        let iconSize = currentIconSize
        let visualScale = currentEffectiveIconScale
        switch model.pages[currentPage][indexPath.item] {
        case .app(let id):
            guard let record = model.record(for: id) else { return cell }
            let cache = iconCache
            let displayName = model.displayName(for: record)
            let expectedKey = record.iconCacheKey
            // Round 13 §F: diagnosed "ページ移動後にアプリアイコンが一瞬
            // ちらつく/消える" — this cell used to *always* configure with a
            // blank `NSImage()` first and only pick up the real icon once
            // the `Task` below completed, even when `cache` already had the
            // icon warm in memory (`prefetchAdjacentPageIcons()` normally
            // ensures this for a page reached via a normal swipe/jump).
            // Entering `Task { @MainActor in ... }` always defers to a
            // later run-loop turn no matter how fast the awaited work
            // resolves, so every `jumpToPage` reload guaranteed at least one
            // rendered frame of blank icons before — this is the flicker.
            // Mirrors `SnapshotDataSource`'s existing synchronous
            // `cachedIconIfAvailable` peek (used for the drag-neighbor
            // snapshot) — falling back to the async path only on a genuine
            // cache miss.
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
            if !previews.isEmpty {
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
