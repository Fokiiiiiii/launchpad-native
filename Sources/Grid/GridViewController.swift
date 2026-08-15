import AppKit
import Catalog
import Diagnostics
import Localization
import Persistence
import WindowBrowser

/// Tried as the first hypothesis while root-causing "the grabbed icon
/// doesn't move" via genuine CGEvent-driven drag testing (not synthetic
/// `window.sendEvent` — the first time this codebase could exercise a
/// real, continuous OS-level drag): a plain `NSImageView` is a perfectly
/// normal hit-testable view, and `createFloatingDragView` adds it *on top
/// of* `collectionView` (`positioned: .above`), directly under the
/// cursor. Making it hit-test-transparent turned out NOT to fix the bug on
/// its own (measured: `mouseDragged` still stopped after the first event
/// with this alone) — the real cause was `cell.view.isHidden = true`, see
/// that call site's doc comment. Kept anyway as cheap, correct defense in
/// depth: a purely decorative/passthrough overlay still shouldn't be
/// hit-testable, on the same principle as `NonInteractiveGlassEffectView`
/// in `GlassBackgroundView.swift`, even though it wasn't this bug's cause.
private final class NonInteractiveImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

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
/// Opaque AppKit monitor tokens are not statically Sendable. Wrapping the
/// token lets the controller release it from its nonisolated deinit without
/// exposing the erased Any value to Swift 6's deinitialization checks.
private final class EventMonitorToken: @unchecked Sendable {
    private let token: Any

    init(_ token: Any) {
        self.token = token
    }

    func remove() {
        NSEvent.removeMonitor(token)
    }
}

public final class GridViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let itemIdentifier = NSUserInterfaceItemIdentifier("GridCellItem")

    private let model: GridModel
    private let iconCache: IconCache
    private var prefetchTask: Task<Void, Never>?
    private var prefetchGeneration = 0
    private var dockReflowTask: Task<Void, Never>?
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

    private var currentPage = 0
    private var folderOverlayBackdrop: FolderOverlayBackdropView?
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
    private var folderContentsViewController: FolderContentsViewController?
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
        dockReflowTask?.cancel()
        itemDragGlobalMouseUpMonitor?.remove()
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
        collectionView.onItemMouseDown = { [weak self] indexPath, event in self?.handleItemMouseDown(indexPath: indexPath, event: event) }
        collectionView.onItemMouseDragged = { [weak self] event in self?.handleItemMouseDragged(event: event) }
        collectionView.onItemMouseUp = { [weak self] event in self?.handleItemMouseUp(event: event) }
        collectionView.onBackgroundClick = { [weak self] in
            // Extra safety-net opportunity for the page-drag machinery (see
            // `resetDragStateIfNeeded`'s doc comment) — harmless no-op if
            // no drag is active.
            self?.resetDragStateIfNeeded()
            self?.cancelItemDragIfNeeded()
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

    public override func viewDidAppear() {
        super.viewDidAppear()
        updatePageControlBottomMargin()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        // `LauncherWindowController.show()` changes a reused panel from its
        // previous screen/size immediately before ordering it front. At that
        // moment `viewDidAppear` can still observe the old geometry. Running
        // this after the final Auto Layout pass keeps the bottom safe area
        // correct for warm opens, display moves, and a Dock revealed over an
        // auto-hidden configuration.
        updatePageControlBottomMargin()
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
        scheduleDockReflow()
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
        scheduleDockReflow()
        return dockInset
    }

    /// A Dock reveal changes the outer scroll view's clip height after the
    /// page-control constraint has moved. AppKit does not guarantee that a
    /// custom collection layout will be prepared again for that constraint
    /// change, so explicitly invalidate it on the next run-loop turn, after
    /// Auto Layout has committed the new viewport size. The coalescing guard
    /// avoids retaining a separate task for every repeated callback.
    private func scheduleDockReflow() {
        guard dockReflowTask == nil else { return }
        dockReflowTask = Task { @MainActor [weak self] in
            defer { self?.dockReflowTask = nil }
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard let self, !Task.isCancelled else { return }
            self.view.layoutSubtreeIfNeeded()
            self.layout.invalidateLayout()
            self.collectionView.collectionViewLayout?.invalidateLayout()
            self.collectionView.layoutSubtreeIfNeeded()
        }
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
        let exitSpring = Self.springAnimation(
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

                let entrySpring = Self.springAnimation(
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

    /// Local copy of `LauncherWindowController`'s damping-ratio/response ->
    /// `CASpringAnimation` conversion (see apple-design's spring guidance):
    /// `Grid` sits *below* `Launcher` in the dependency graph (`Launcher`
    /// depends on `Grid`, not the reverse), so that helper can't be reused
    /// from here — duplicating this small formula locally is simpler than
    /// introducing a cross-module dependency inversion or a new shared
    /// target just for ~10 lines of math.
    private static func springAnimation(
        keyPath: String,
        from: CGFloat,
        to: CGFloat,
        damping dampingRatio: CGFloat,
        response: CGFloat,
        initialVelocity: CGFloat = 0
    ) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        let angularFrequency = 2 * .pi / response
        let stiffness = angularFrequency * angularFrequency
        animation.mass = 1
        animation.stiffness = stiffness
        animation.damping = 2 * dampingRatio * sqrt(stiffness)
        animation.initialVelocity = initialVelocity
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        animation.isRemovedOnCompletion = true
        return animation
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
                    let xOffset = dragDirection > 0 ? width : -width
                    let imageView = NSImageView(frame: NSRect(
                        x: scrollView.frame.origin.x + xOffset,
                        y: scrollView.frame.origin.y,
                        width: scrollView.frame.width,
                        height: scrollView.frame.height
                    ))
                    imageView.image = image
                    imageView.imageScaling = .scaleNone
                    imageView.wantsLayer = true
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
            let resisted = Self.rubberBand(abs(deltaX), dimension: edgePullLimit)
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

        let spring = Self.springAnimation(
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
    /// 1s fallback timer, a background click during a drag, and every time
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

    /// A permanently-off-screen, never-ordered-visible host window, reused
    /// across every snapshot render. `cacheDisplay(in:to:)` re-drives a
    /// view's normal display path — for a layer-backed hierarchy (every
    /// `GridCellItem` sets `view.wantsLayer = true`), that path only
    /// produces real pixel content once the view has actually been asked to
    /// display by a real window's rendering machinery at least once. A
    /// view that has never belonged to any `NSWindow` (the original
    /// implementation here) never gets that: `cacheDisplay` still reports
    /// success (returns a non-nil bitmap) but every pixel comes back fully
    /// transparent. Confirmed empirically via `debugSimulatePageDrag` +
    /// `log stream`: a since-removed pixel-sampling diagnostic read
    /// "0/64 sampled points non-transparent" before this fix — this is what the user's report ("next page's
    /// content isn't visible during the drag") was actually seeing; the
    /// snapshot mechanism itself was working (non-nil, correctly
    /// positioned/transformed), it just had nothing drawn in it. Parking
    /// the render host far outside any real display's coordinate space
    /// (rather than merely `alphaValue = 0` on-screen) keeps this
    /// invisible to the user while still giving AppKit a real window to
    /// render into.
    ///
    /// Ordered front exactly once, right here, and never ordered out again
    /// — a real, confirmed follow-up regression: the first version of this
    /// fix called `orderFront`/`orderOut` on every single drag gesture (in
    /// `renderPageSnapshot`, once direction resolves), and a user report of
    /// a brief flicker on every page move followed shortly after that fix
    /// shipped. Repeatedly ordering *any* real window in and out of the
    /// window list — even one permanently parked off-screen — still forces
    /// a WindowServer-level composite pass each time, which is a plausible
    /// source of a screen-wide flicker distinct from the earlier "flash of
    /// the previous page's content" bug (already fixed in `finishPageDrag`).
    /// Ordering front once, up front, still satisfies `cacheDisplay`'s
    /// requirement that the view belong to a window that's actually been
    /// displayed — there's no need to repeat it per gesture, and since the
    /// window never visually appears anywhere real, there's no downside to
    /// leaving it ordered front indefinitely.
    private static let snapshotHostWindow: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.orderFront(nil)
        return window
    }()

    /// Renders `model.pages[page]` into a standalone offscreen
    /// `NSCollectionView` (its own `PagedGridLayout`, sized to match the
    /// live grid exactly) and rasterizes it to a static image via
    /// `cacheDisplay(in:to:)`. Icons use `IconCache.cachedIconIfAvailable`
    /// (synchronous, best-effort) rather than the live grid's async
    /// `icon(for:)` fetch — waiting on a disk/system icon load would delay
    /// the drag's very first frame, and every icon on any page the user has
    /// already seen is normally already memory-cached by this point. A
    /// genuinely never-seen page's icons render blank until the real grid
    /// takes back over at the end of the drag — an accepted, minor
    /// trade-off, not a bug.
    private func renderPageSnapshot(forPage page: Int, size: NSSize) -> NSImage? {
        guard model.pages.indices.contains(page) else { return nil }

        let tempLayout = PagedGridLayout()
        tempLayout.settings = model.gridSettings
        let tempCollectionView = NSCollectionView(frame: NSRect(origin: .zero, size: size))
        tempCollectionView.collectionViewLayout = tempLayout
        tempCollectionView.register(GridCellItem.self, forItemWithIdentifier: itemIdentifier)
        tempCollectionView.backgroundColors = [.clear]

        let dataSource = SnapshotDataSource(
            items: model.pages[page],
            model: model,
            iconCache: iconCache,
            itemIdentifier: itemIdentifier,
            iconSize: currentIconSize,
            visualScale: currentEffectiveIconScale
        )
        // `dataSource` is only needed for this synchronous render (no
        // async work happens between here and the function returning), so
        // the local `let` staying in scope through `cacheDisplay` is
        // sufficient — `NSCollectionView.dataSource` itself doesn't retain.
        tempCollectionView.dataSource = dataSource
        tempCollectionView.reloadData()

        // See `snapshotHostWindow`'s doc comment: this view must actually
        // belong to a real window before `cacheDisplay` will capture
        // anything but transparent pixels from its layer-backed cells. The
        // window is already ordered front permanently (once, at creation) —
        // only the content view is swapped in/out here, per gesture.
        let hostWindow = Self.snapshotHostWindow
        hostWindow.setContentSize(size)
        hostWindow.contentView = tempCollectionView
        tempCollectionView.layoutSubtreeIfNeeded()
        tempCollectionView.displayIfNeeded()

        defer {
            hostWindow.contentView = nil
        }

        guard let bitmap = tempCollectionView.bitmapImageRepForCachingDisplay(in: tempCollectionView.bounds) else { return nil }
        tempCollectionView.cacheDisplay(in: tempCollectionView.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    /// Apple's standard rubber-band resistance formula (see apple-design's
    /// guidance): resistance increases with overshoot instead of a hard
    /// stop, so dragging past an end still moves but doesn't go far.
    private static func rubberBand(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
        (overshoot * dimension * constant) / (dimension + constant * abs(overshoot))
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
    public func debugOpenFirstFolder() {
        guard model.pages.indices.contains(currentPage) else { return }
        guard let index = model.pages[currentPage].firstIndex(where: {
            if case .folder = $0 { return true }
            return false
        }), case .folder(let folderID) = model.pages[currentPage][index] else {
            DiagnosticsLog.launcher.info("debugOpenFirstFolder: no folder on page \(self.currentPage, privacy: .public)")
            return
        }
        DiagnosticsLog.launcher.info("debugOpenFirstFolder: opening folder at index \(index, privacy: .public)")
        openFolder(folderID, anchorIndexPath: IndexPath(item: index, section: 0))
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.itemDragFolderHoverDelay + 0.15) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseUp, at: targetPoint, in: self.collectionView))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    Task { @MainActor in
                        let pageCounts = self.model.pages.map(\.count)
                        let folderCount = self.model.folders.count
                        DiagnosticsLog.grid.notice("debugSimulateItemDrag: settled — page counts=\(pageCounts, privacy: .public), folder count=\(folderCount, privacy: .public), activeDrag=\(self.activeItemDrag != nil, privacy: .public)")
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

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.itemDragFolderHoverDelay + 0.15) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                window.sendEvent(Self.syntheticMouseEvent(type: .leftMouseUp, at: secondEnd, in: self.collectionView))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    Task { @MainActor in
                        let pageCounts = self.model.pages.map(\.count)
                        DiagnosticsLog.grid.notice("debugSimulateInterruptedItemDrag: settled — page counts=\(pageCounts, privacy: .public), activeDrag=\(self.activeItemDrag != nil, privacy: .public)")
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
            openFolder(folderID, anchorIndexPath: indexPath)
        }
    }

    /// Full-screen dimmed take-over, matching the user-supplied "Tessera"
    /// design reference's own `FolderOverlay` exactly (explicit request:
    /// "フォルダ名の中身は全画面で表示されるzipのやつにして") — a small
    /// anchored `NSPopover` (this project's prior, safer choice) was
    /// rejected as not matching. Deliberately keeps `FolderContentsViewController`
    /// and all of its already-proven AppKit interaction code (click-to-
    /// launch, right-click context menu, drag-out-to-remove) completely
    /// unchanged — only the *presentation container* changes, from an
    /// anchored popover to a full-bounds dimming backdrop with the same
    /// content view centered within it. This avoids re-risking interaction
    /// logic that's already been fixed multiple times in this project's
    /// history for a purely visual change.
    private func openFolder(_ folderID: FolderID, anchorIndexPath: IndexPath) {
        let start = DispatchTime.now()
        guard model.folders[folderID] != nil else { return }

        // The reference's own `FolderOverlay` is a full-screen `ZStack`
        // sibling covering the *entire* launcher (search bar included) —
        // not scoped to just the grid area. `GridViewController.view` itself
        // is only the bottom ~954pt of the 1050pt-tall window (the search
        // bar occupies the top ~96pt as a sibling within
        // `LauncherViewController.view`), so anchoring the backdrop to
        // `view` left the search bar strip completely undimmed/unblurred
        // while a folder was open — a real, confirmed visual bug
        // ("上の部分がおかしい": the search bar area read as a bright,
        // untouched strip floating above the darkened grid instead of
        // being part of the same full-screen overlay). `view.window?
        // .contentView` is the window's actual full-bounds root view (see
        // `LauncherWindowController.makeWindow`'s own `root`), so anchoring
        // there instead covers the whole screen, exactly like the
        // reference.
        let hostView = view.window?.contentView ?? view

        let itemCount = model.folders[folderID]?.pages.reduce(0) { $0 + $1.count } ?? 0
        let configuredColumns = max(model.gridSettings.columns, 1)
        let folderColumns = FolderContentsViewController.displayedColumnCount(
            itemCount: itemCount,
            configuredColumns: configuredColumns
        )
        let panelWidth = FolderContentsViewController.panelWidth(
            availableWidth: hostView.bounds.width - 192,
            columns: folderColumns,
            iconSize: CGFloat(currentIconSize * currentEffectiveIconScale),
            usesWideLayout: itemCount >= configuredColumns
        )

        let folderVC = FolderContentsViewController(
            model: model,
            folderID: folderID,
            iconCache: iconCache,
            // The open-folder tiles are SwiftUI content rather than
            // `GridCellItem`, so they do not receive the cell layer transform
            // below. Pass the same effective visual size into that surface so
            // its mosaic and card height follow the main grid scale.
            iconSize: currentIconSize * currentEffectiveIconScale,
            columns: folderColumns,
            panelWidth: panelWidth,
            onLaunch: { [weak self] record in
                self?.closeFolderOverlay()
                self?.onLaunch(record)
            },
            onItemDraggedOut: { [weak self] folderPage, folderIndex in
                guard let self else { return }
                self.model.removeFromFolder(folderID, folderPage: folderPage, folderIndex: folderIndex, toPage: self.currentPage)
                Task { await self.model.save() }
            }
        )
        folderVC.loadViewIfNeeded()

        let backdrop = FolderOverlayBackdropView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.onDismiss = { [weak self] in self?.closeFolderOverlay() }

        // Blurs the grid behind the overlay, then darkens on top — matches
        // the reference's `blur(22px)` + `rgba(8,8,9,.55)` exactly (a flat
        // dim color alone, the previous implementation, left the grid
        // sharply visible underneath instead of visibly blurred).
        let blur = NonInteractiveFolderBlurView(frame: backdrop.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .fullScreenUI
        blur.blendingMode = .withinWindow
        blur.state = .active
        backdrop.addSubview(blur)

        let tint = NSView(frame: backdrop.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        backdrop.addSubview(tint)

        let panel = folderVC.view
        backdrop.addSubview(panel)
        hostView.addSubview(backdrop)

        let size = folderVC.preferredContentSize
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: hostView.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])

        // `panel` is positioned via a direct, one-time frame assignment —
        // not Auto Layout constraints — see `FolderContentsViewController
        // .loadView()`'s doc comment for why (a real, confirmed regression
        // where AppKit's own `preferredContentSize`-mirrored width
        // constraint intermittently won over an explicit Auto Layout
        // constraint of equal or higher priority). `backdrop`'s eventual
        // size is already known here without waiting for its own Auto
        // Layout resolution: it's pinned 1:1 to `hostView`'s edges above, so
        // its size always equals `hostView.bounds.size` (already read into
        // `panelWidth`). 96pt side insets match the reference's own
        // `.padding(.horizontal, TSLayout.folderPanelInsetH)` exactly.
        //
        // Vertically centered on screen rather than the reference's own
        // literal fixed `.padding(.top, 196)` — a real, confirmed complaint
        // ("画面の中央からずれてる"): the reference's fixed offset assumes a
        // card tall enough to roughly fill the remaining space below it,
        // but for a folder with only a couple of rows the card ends up far
        // short of the 480pt height cap, leaving a much bigger gap below
        // the card than above it — reading as pushed toward the top rather
        // than centered. True vertical centering keeps the composition
        // balanced regardless of how many rows the folder actually has,
        // and matches the broader macOS convention of centering modal-style
        // overlays (Quick Look, alerts, About panels) rather than pinning
        // them to a fixed offset tuned for one specific content size.
        let backdropSize = hostView.bounds.size
        panel.frame = NSRect(
            x: (backdropSize.width - size.width) / 2,
            y: (backdropSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        // Forces `root`'s internal Auto Layout children (title/scroll view/
        // hosted SwiftUI grid, all pinned to `root`'s now-final frame) to
        // resolve synchronously against that frame before the entrance
        // animation starts, rather than depending on some later, unrelated
        // event (an async icon load's own `layoutIfNeeded()` call) to
        // eventually force the correct layout — the same class of
        // intermittent race already fixed once for the icon-trickle case in
        // `FolderContentsViewController.refresh()`.
        panel.layoutSubtreeIfNeeded()

        folderOverlayBackdrop?.removeFromSuperview()
        folderOverlayBackdrop = backdrop
        folderContentsViewController = folderVC
        view.window?.makeFirstResponder(backdrop)

        backdrop.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            backdrop.animator().alphaValue = 1
        }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        DiagnosticsLog.launcher.info("folder transition: build+show full-screen overlay took \(ms, privacy: .public)ms")
    }

    private func closeFolderOverlay() {
        guard let backdrop = folderOverlayBackdrop else { return }
        folderOverlayBackdrop = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            backdrop.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                backdrop.removeFromSuperview()
                self?.folderContentsViewController = nil
            }
        })
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
                open: { [weak self] in self?.openFolder(folderID, anchorIndexPath: indexPath) },
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

    // MARK: Item drag (lift, live reorder, folder creation, page-turn)
    //
    // Replaces NSCollectionView's built-in click/selection/drag machinery
    // entirely for cell content (see `GridCollectionView.onItemMouseDown`'s
    // doc comment for why): that machinery fires selection synchronously on
    // mouseDown before it's known whether the gesture continues into a drag
    // (a real, confirmed regression from an earlier round — dragging opened
    // the app instead of moving it), and has no notion of live neighbor
    // displacement, folder-candidate hover zones, or drag-triggered page
    // turning — the user's explicit "iOS home screen" interaction ask,
    // detailed in a pasted specification this design follows (adapted from
    // its SwiftUI-flavored pseudocode to this project's AppKit/CALayer
    // idioms, which is what actually works reliably in this codebase — see
    // the page-drag paging section above for the established pattern of
    // direct `transform.translation.x/y` manipulation this reuses).
    //
    // Deliberately deferred out of this pass (flagged, not silently
    // dropped): the spec's precise geometric hysteresis band (distinct from
    // the debounce-timer approach used here), Cmd+Arrow/Option+Arrow
    // keyboard reorder/page-move shortcuts, dragging an icon out to the
    // real Dock (previously free via NSCollectionView's native drag
    // session + `.fileURL` pasteboard type — removed along with that
    // machinery), and giving `FolderContentsViewController`'s own grid the
    // same rich system (it keeps its prior, simpler reorder behavior).

    /// `@unchecked Sendable`: `Timer.scheduledTimer`'s completion closure is
    /// technically a non-isolated context by Swift 6's rules, but in
    /// practice it always fires on the main run loop (the same actor this
    /// entire view controller is isolated to) — there is no real
    /// cross-thread access here, just the compiler unable to see that a
    /// `Timer` scheduled from `@MainActor` code stays on that same thread.
    private final class ItemDragSession: @unchecked Sendable {
        let sourcePage: Int
        let sourceOriginalIndex: Int
        let draggedItem: LayoutItem
        let originalFrame: NSRect
        /// The floating view's frame, in the top-level host coordinates, set exactly
        /// once at creation and never reassigned — see `updateItemDrag`'s
        /// doc comment for why: all *movement* after that happens purely
        /// via `transform.translation.x/y`, matching every other continuous
        /// drag in this codebase (page-drag, reorder preview). Needed here
        /// as the fixed baseline those translation deltas are computed from.
        var floatingViewOriginalFrameInHost: NSRect = .zero
        /// Offset from the cell's origin to where the user actually grabbed
        /// it — respected while following the cursor so the icon doesn't
        /// jump to be centered under the pointer (apple-design's direct-
        /// manipulation guidance).
        let grabOffset: NSPoint
        var floatingView: NSView?
        weak var floatingViewHost: NSView?
        var candidateSlot: Int
        var pendingRawSlot: Int
        var folderCandidateOriginalIndex: Int?
        var pendingRawFolderCandidateIndex: Int?
        var edgeDirection: Int = 0
        /// Last raw drag point (collectionView-local), refreshed on every
        /// `updateItemDrag` call — reused by `commitPageTurnDuringDrag` to
        /// re-evaluate candidates on the new page without needing to derive
        /// a point back out of the floating view's (now `.frame`-immutable)
        /// position.
        var lastPoint: NSPoint = .zero
        var reorderTimer: Timer?
        var folderTimer: Timer?
        var edgeTimer: Timer?
        /// Round 12 §8b: the incoming-page preview shown while the pointer
        /// dwells in the edge zone, before the dwell timer actually commits
        /// a page turn. `nil` whenever the pointer isn't currently in an
        /// edge zone.
        var edgePeekImageView: NSImageView?
        /// Last offset/timestamp applied to the peek — reused by §8c to
        /// approximate a release velocity when the page-turn commit spring
        /// re-targets a peek that's still easing.
        var lastPeekOffset: CGFloat?
        var lastPeekTime: CFTimeInterval?
        /// Real, confirmed report ("グループ化しようとするとアプリが逃げる
        /// ...わかりやすくできない？"): a standalone overlay (same pattern
        /// as `floatingView`/`edgePeekImageView` — never a sublayer added to
        /// a reusable `GridCellItem`, since `prepareForReuse` only resets
        /// that cell's own transform/opacity/animations, not arbitrary
        /// sublayers someone else added) that shows the folder drop zone's
        /// bounds and a hover-progress sweep. `nil` whenever the pointer
        /// isn't currently over another app's center zone.
        var folderZoneIndicatorView: NSView?
        /// Where the dragged item currently sits *on the page being shown*, or
        /// `nil` once a mid-drag page turn has carried the drag onto a page the
        /// item isn't part of.
        ///
        /// `sourceOriginalIndex` is a `let` describing the item's index on its
        /// **origin** page, which is what `endItemDrag` needs for the model
        /// mutation. Everything that reasons about the *currently displayed*
        /// page — which cell to exclude from the reorder preview, which cells
        /// can be folder targets, how many slots exist — was reading that same
        /// value, so after `commitPageTurnDuringDrag` it pointed at an
        /// unrelated app on the new page: the preview excluded the wrong cell
        /// (shifting every following slot by one), that app could not be made
        /// into a folder, and the slot count was short by one so the item could
        /// not be dropped at the end. `commitPageTurnDuringDrag` already resets
        /// `pendingRawSlot`/`candidateSlot`/`edgeDirection`/folder-candidate
        /// state for the new page for exactly this class of reason; this is the
        /// remaining piece of that same reset.
        var sourceIndexOnCurrentPage: Int?
        let generation: Int

        init(sourcePage: Int, sourceOriginalIndex: Int, draggedItem: LayoutItem, originalFrame: NSRect, grabOffset: NSPoint, generation: Int) {
            self.sourcePage = sourcePage
            self.sourceOriginalIndex = sourceOriginalIndex
            self.draggedItem = draggedItem
            self.originalFrame = originalFrame
            self.grabOffset = grabOffset
            self.candidateSlot = sourceOriginalIndex
            self.pendingRawSlot = sourceOriginalIndex
            self.sourceIndexOnCurrentPage = sourceOriginalIndex
            self.generation = generation
        }

        func invalidateTimers() {
            reorderTimer?.invalidate()
            folderTimer?.invalidate()
            edgeTimer?.invalidate()
        }
    }

    private var pendingItemPress: (indexPath: IndexPath, startPoint: NSPoint)?
    private var activeItemDrag: ItemDragSession?
    /// A mouse click tracks `collectionView.selectionIndexPaths` (needed for
    /// drag/launch/context-menu targeting) but must NOT draw the visible
    /// highlight ring — a real user found the box+glow that appeared around
    /// every clicked icon distracting ("アプリをいじった時に出る白い枠は基本
    /// 的に出ないように"). Keyboard arrow-key browsing (`moveSelection`/
    /// `select`) is the one case that should still show it, since without
    /// any visual feedback there'd be no way to see where keyboard focus is.
    private var keyboardSelectionActive = false
    private var itemDragGeneration = 0
    /// Round 12 §8c: lightweight velocity approximation for
    /// `animateLayerTranslation`'s re-targeted springs (reorder-preview
    /// shift, item-drag page-turn) — keyed by layer identity so a cell
    /// reused for a *different* record on a later drag never inherits a
    /// stale velocity estimate. Cleared in `endItemDrag`/`revertItemDrag`.
    private var lastAnimatedValueByLayer: [ObjectIdentifier: (x: CGFloat, xTime: CFTimeInterval, y: CGFloat, yTime: CFTimeInterval)] = [:]

    private static let itemDragThresholdDistance: CGFloat = 6
    private static let itemDragEdgeZoneWidth: CGFloat = 70
    private static let itemDragEdgeHoverDelay: TimeInterval = 0.45
    /// Real, confirmed report ("フォルダ判定をもう少し遅く"): 0.5s let a
    /// brief pass-over during reordering register as folder intent too
    /// easily. Raised to 0.7s — still well under a full second (doesn't
    /// read as unresponsive) but requires more deliberate dwell before
    /// committing. The hover-progress ring's own sweep duration and the
    /// debug-hook wait both read this constant directly, so both track the
    /// new value automatically.
    private static let itemDragFolderHoverDelay: TimeInterval = 0.7
    /// iOS's own folder-creation highlight reads as "a little more than the
    /// icon," not a separate shape — noticeably but not dramatically larger
    /// than the icon it wraps. 1.18x keeps the padding visible without the
    /// indicator ballooning into neighboring cells at tight column counts.
    private static let itemDragFolderZoneIndicatorScale: CGFloat = 1.18
    /// Deliberately rounder than `GridCellItem`'s own app-icon squircle
    /// ratio (0.236, `applyIconSize`) — this is a plain rounded-square
    /// backdrop, not an icon mask, and a plumper curve reads as
    /// "background" rather than "blank icon."
    private static let itemDragFolderZoneIndicatorCornerRatio: CGFloat = 0.28
    /// Real, confirmed report ("上からやってもなんの反応もない"): now that
    /// the 2D hysteresis radius below is the sole anti-chatter gate (see its
    /// doc comment), this additional time delay only added pure lag on top
    /// — dropped to 0. The `Timer` mechanism itself is unchanged so a future
    /// tuning pass can reintroduce a nonzero value without restructuring
    /// anything.
    private static let itemDragReorderDebounce: TimeInterval = 0.0
    private static let itemDragFolderZoneInset: CGFloat = 0.2 // ~60% center region
    /// Round 12 §8a: the pointer must move this fraction of a cell's own
    /// short side past the committed slot's center before the candidate slot
    /// is allowed to change at all — a real hysteresis band (spec 7.3)
    /// around the current selection, replacing the old "any raw nearest-slot
    /// change restarts the debounce timer" behavior, which could still
    /// flicker if the pointer sat right on a cell boundary. Real, confirmed
    /// report ("狙った位置にアプリを置いてもそこにあるアプリが動かない"):
    /// judging this from `point.x` alone made straight vertical drags onto
    /// a different row never satisfy the crossing condition — this is now a
    /// straight-line distance from the committed cell's center, so movement
    /// in any direction (including pure vertical) can cross it. Raised
    /// slightly from 0.15 to 0.18 alongside dropping the debounce above to
    /// 0 — with hysteresis now the *only* anti-chatter layer (instead of
    /// splitting the job with a time delay), a touch more radius keeps
    /// boundary flicker damped without feeling sluggish.
    private static let itemDragHysteresisFraction: CGFloat = 0.18
    /// Real, confirmed report ("ページ端についてその先へ無理や進もうとし
    /// た時に起きるアニメーションが過剰すぎる"): the old linear
    /// `proximity * 30` formula meant the preview kept growing the harder
    /// the pointer pushed toward the edge, with no natural ceiling short of
    /// the zone's own zero/one clamp. `updateEdgePeek` now runs the
    /// penetration distance through the existing `rubberBand` helper
    /// (already used for the trackpad page-swipe's own edge resistance)
    /// instead — overshoot-proportional resistance rather than a hard
    /// linear ramp. This constant is the rubber band's `dimension`
    /// term (how quickly it saturates), not a maximum offset: measured
    /// output for `itemDragEdgeZoneWidth`(70)-sized penetration is ≈14.8pt,
    /// and ≈5.8pt at 14pt of penetration — both comfortably below the old
    /// linear formula's up-to-30pt sweep.
    private static let itemDragEdgePeekResistanceDimension: CGFloat = 24

    private func handleItemMouseDown(indexPath: IndexPath, event: NSEvent) {
        guard model.pages.indices.contains(currentPage), model.pages[currentPage].indices.contains(indexPath.item) else { return }
        // Real, confirmed bug caught live via log stream during actual user
        // testing: a fresh mouseDown on a DIFFERENT item can arrive while
        // `activeItemDrag` is still set from a previous gesture whose own
        // mouseUp never reached us (the same real-world AppKit routing gap
        // the global mouseUp monitor below exists for — a single pointer
        // can't genuinely have two concurrent presses). Left unhandled, this
        // method only overwrote `pendingItemPress`, leaving the stale session
        // active — and `handleItemMouseDragged` checks `activeItemDrag`
        // before `pendingItemPress`, so every subsequent drag update kept
        // moving the FIRST (stale) item while the user believed they'd
        // grabbed the new one. Matches the reported symptom exactly:
        // "after one drag breaks, dragging a different app moves the first
        // app instead." Commit the stale session now, using its own
        // last-tracked position, before handling this new press — the same
        // treatment the global monitor gives a genuinely lost mouseUp.
        if let staleSession = activeItemDrag {
            DiagnosticsLog.grid.notice("handleItemMouseDown: new press on item \(indexPath.item, privacy: .public) arrived while item \(staleSession.sourceOriginalIndex, privacy: .public)'s drag was still active — committing the stale session first")
            endItemDrag(session: staleSession)
        }
        // Real, confirmed regression: this used to call
        // `collectionView.reloadItems(at: [indexPath])` right here to make
        // the selection highlight visible. Reloading the very cell that's
        // mid-mouseDown reconfigures (and can recreate) its view instance —
        // AppKit routes subsequent mouseDragged/mouseUp to whichever view
        // received mouseDown, so swapping that view out from under an
        // in-flight press broke every drag entirely (dragging did nothing
        // at all). Toggling the highlight directly on the already-existing
        // live cell views avoids touching the view identity mid-gesture.
        let previousSelection = collectionView.selectionIndexPaths
        keyboardSelectionActive = false
        collectionView.selectionIndexPaths = [indexPath]
        for previous in previousSelection where previous != indexPath {
            (collectionView.item(at: previous) as? GridCellItem)?.applySelection(false)
        }
        // No `applySelection(true)` here — a mouse click tracks selection
        // state without drawing the ring (see `keyboardSelectionActive`'s
        // doc comment).
        (collectionView.item(at: indexPath) as? GridCellItem)?.applySelection(false)

        let point = collectionView.convert(event.locationInWindow, from: nil)
        pendingItemPress = (indexPath, point)
        applyPressFeedback(at: indexPath, pressed: true)
    }

    private func handleItemMouseDragged(event: NSEvent) {
        let point = collectionView.convert(event.locationInWindow, from: nil)
        if let session = activeItemDrag {
            updateItemDrag(session: session, point: point)
            return
        }
        guard let pending = pendingItemPress else { return }
        let distance = hypot(point.x - pending.startPoint.x, point.y - pending.startPoint.y)
        guard distance >= Self.itemDragThresholdDistance else { return }
        beginItemDrag(indexPath: pending.indexPath, pressPoint: pending.startPoint, currentPoint: point)
    }

    private func handleItemMouseUp(event: NSEvent) {
        if let session = activeItemDrag {
            endItemDrag(session: session)
            return
        }
        guard let pending = pendingItemPress else { return }
        pendingItemPress = nil
        applyPressFeedback(at: pending.indexPath, pressed: false)
        activate(at: pending.indexPath)
    }

    /// Cancels any in-progress item drag, reverting to the original
    /// arrangement — reachable from a background click (mirrors the
    /// page-drag machinery's own safety net) and available for a future
    /// Escape-key wire-up.
    ///
    /// Also called every time the launcher is shown, which is what
    /// `resetDragStateIfNeeded()` already guarantees for the *page*-drag
    /// machinery: however a previous session ended, the next open starts
    /// clean. Item drags had no equivalent entry point.
    public func cancelItemDragIfNeeded() {
        guard let session = activeItemDrag else { return }
        DiagnosticsLog.grid.notice("cancelItemDragIfNeeded: reverting drag of item \(session.sourceOriginalIndex, privacy: .public)")
        revertItemDrag(session: session)
    }

    /// Spec 28.1: a light press-down scale, distinct from the drag lift —
    /// this alone doesn't commit to launching (mouseUp on the same item
    /// without exceeding the drag threshold does that in `handleItemMouseUp`).
    private func applyPressFeedback(at indexPath: IndexPath, pressed: Bool) {
        guard let cell = collectionView.item(at: indexPath) as? GridCellItem, let layer = cell.view.layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.transform = CATransform3DMakeScale(pressed ? 0.96 : 1.0, pressed ? 0.96 : 1.0, 1)
        CATransaction.commit()
    }

    private func beginItemDrag(indexPath: IndexPath, pressPoint: NSPoint, currentPoint: NSPoint) {
        pendingItemPress = nil
        guard model.pages.indices.contains(currentPage), model.pages[currentPage].indices.contains(indexPath.item),
              let attributes = layout.layoutAttributesForItem(at: indexPath) else { return }
        let item = model.pages[currentPage][indexPath.item]
        itemDragGeneration += 1
        let grabOffset = NSPoint(x: pressPoint.x - attributes.frame.minX, y: pressPoint.y - attributes.frame.minY)
        let session = ItemDragSession(
            sourcePage: currentPage,
            sourceOriginalIndex: indexPath.item,
            draggedItem: item,
            originalFrame: attributes.frame,
            grabOffset: grabOffset,
            generation: itemDragGeneration
        )
        activeItemDrag = session
        DiagnosticsLog.grid.notice("beginItemDrag: item \(indexPath.item, privacy: .public) on page \(self.currentPage, privacy: .public)")
        startWobble()
        createFloatingDragView(session: session)
        updateItemDrag(session: session, point: currentPoint)
        armItemDragSafetyNets(generation: session.generation)
    }

    /// Real, confirmed bug found via a genuine (not simulated) trackpad
    /// drag on this exact codebase: `mouseDown` -> `mouseDragged` ->
    /// `beginItemDrag` all fired correctly, but `mouseUp` never arrived —
    /// AppKit's per-window mouse-tracking continuity (the mechanism
    /// `GridCollectionView`'s override relies on) isn't guaranteed if the
    /// pointer leaves the window's bounds, key status changes, or a handful
    /// of other real-world edge cases a synthetic in-bounds test never hits.
    /// Without a way out, `activeItemDrag` stayed non-nil forever — the
    /// floating icon stuck on screen, and every subsequent
    /// `handleItemMouseDown` treating the grid as still mid-drag,
    /// effectively freezing all grid interaction ("操作が効かない"). Two
    /// independent nets, matching the page-drag machinery's own established
    /// pattern:
    ///  1. A fixed, generous fallback timer (far longer than any real
    ///     drag) that force-reverts no matter what.
    ///  2. A *global* mouse-up monitor — catches a real mouseUp AppKit
    ///     delivered somewhere else entirely (a different view/window)
    ///     instead of back to `GridCollectionView`, which the per-window
    ///     tracking continuity alone can miss.
    private static let itemDragSafetyNetTimeout: TimeInterval = 15.0
    private var itemDragGlobalMouseUpMonitor: EventMonitorToken?

    /// Removes the global mouse-up fallback as soon as an item drag settles.
    /// AppKit does not remove global monitors automatically; leaving one
    /// registered after a drag retains the callback until the controller dies
    /// and makes every later mouse-up pay an unnecessary observer cost.
    private func disarmItemDragSafetyNet() {
        guard let monitor = itemDragGlobalMouseUpMonitor else { return }
        monitor.remove()
        itemDragGlobalMouseUpMonitor = nil
        DiagnosticsLog.grid.debug("disarmItemDragSafetyNet: global mouseUp monitor removed")
    }

    private func armItemDragSafetyNets(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.itemDragSafetyNetTimeout) { [weak self] in
            Task { @MainActor in
                guard let self, let session = self.activeItemDrag, session.generation == generation else { return }
                DiagnosticsLog.grid.notice("armItemDragSafetyNets: fallback timeout fired, force-reverting")
                self.revertItemDrag(session: session)
            }
        }
        guard itemDragGlobalMouseUpMonitor == nil else { return }
        guard let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp],
            handler: { [weak self] _ in
                guard let self, let session = self.activeItemDrag else { return }
                DiagnosticsLog.grid.notice("armItemDragSafetyNets: global mouseUp monitor fired while a drag was still active — GridCollectionView never received it, committing via this fallback instead")
                self.endItemDrag(session: session)
            }
        ) else {
            DiagnosticsLog.grid.error("armItemDragSafetyNets: could not register global mouseUp monitor")
            return
        }
        itemDragGlobalMouseUpMonitor = EventMonitorToken(monitor)
    }

    private func snapshotImage(of view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func createFloatingDragView(session: ItemDragSession) {
        guard let cell = collectionView.item(at: IndexPath(item: session.sourceOriginalIndex, section: 0)) as? GridCellItem else { return }
        let host = view.window?.contentView ?? view
        let image = snapshotImage(of: cell.view)
        host.wantsLayer = true
        host.clipsToBounds = false
        host.layer?.masksToBounds = false
        let frameInHost = collectionView.convert(session.originalFrame, to: host)
        let imageView = NonInteractiveImageView(frame: frameInHost)
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.wantsLayer = true
        imageView.clipsToBounds = false
        imageView.layer?.masksToBounds = false
        imageView.layer?.zPosition = 1000
        imageView.layer?.shadowOpacity = 0.35
        imageView.layer?.shadowRadius = 12
        imageView.layer?.shadowOffset = CGSize(width: 0, height: -6)
        host.addSubview(imageView, positioned: .above, relativeTo: nil)
        session.floatingView = imageView
        session.floatingViewHost = host
        session.floatingViewOriginalFrameInHost = frameInHost
        // Real, confirmed bug found via genuine CGEvent-driven drag testing:
        // setting `cell.view.isHidden = true` here — even though `cell.view`
        // is a descendant of `collectionView`, not `collectionView` itself —
        // silently broke AppKit's mouse-tracking continuity for the rest of
        // the gesture. A live drag would fire `mouseDown` -> the first
        // `mouseDragged` -> `beginItemDrag`, then never receive another
        // `mouseDragged`/`mouseUp` at all, exactly matching "the grabbed
        // icon doesn't move" and "surrounding icons shift oddly" (the
        // reorder-preview path is driven separately and kept animating).
        // Confirmed by toggling only this one line: removing it let 6/6
        // synthetic `mouseDragged` events through and `endItemDrag` commit
        // correctly; restoring it reproduced the 1-event cutoff every time.
        // Same family as the `reloadItems`-mid-mouseDown regression
        // documented above `handleItemMouseDown` — mutating view-hierarchy/
        // visibility state on the actively-tracked view's subtree mid-
        // gesture is unsafe. Fixed by hiding the cell via its `CALayer`
        // opacity instead, which doesn't touch AppKit's view-visibility
        // machinery at all.
        cell.view.layer?.opacity = 0

        // Spec 5.2: a short lift (scale 1.00 -> 1.06), a touch of bounce
        // since a real grab is what triggered it (apple-design: reserve
        // bounce for gesture-driven motion). Reduce Motion keeps the
        // functional feedback (the icon still visibly separates and gets a
        // shadow) without the scale animation itself. Uses the
        // `"transform.scale"` structured keypath (not a raw
        // `CATransform3DMakeScale` assignment to `layer.transform`) so it
        // composes cleanly with the `"transform.translation.x/y"` keypath
        // `updateItemDrag` uses for movement — see that method's doc
        // comment for why mixing `.frame` and `.transform` on the same
        // view was a real, confirmed bug.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let layer = imageView.layer else { return }
        if !reduceMotion {
            layer.setValue(1.06, forKeyPath: "transform.scale")
            layer.add(Self.springAnimation(keyPath: "transform.scale", from: 1.0, to: 1.06, damping: 0.82, response: 0.20), forKey: "lift")
        }
    }

    /// Real, confirmed bug (user report: "the grabbed app flies off
    /// erratically"): the first version of this method repeatedly
    /// reassigned `floatingView.frame.origin` on every drag update, while
    /// the *same* view's layer also carried the lift's scale transform.
    /// `NSView.frame` is computed against the view's untransformed
    /// geometry — reassigning it while a layer transform is simultaneously
    /// active (and, during the lift's spring, still mid-animation) fights
    /// with that transform instead of composing with it, producing
    /// compounding/erratic positional drift. Every other continuous drag in
    /// this codebase (page-drag, reorder preview) avoids this by never
    /// touching `.frame` after initial placement and driving all movement
    /// through the `transform.translation.x/y` keypaths instead, which
    /// compose independently of `transform.scale` — this now does the same.
    private func updateItemDrag(session: ItemDragSession, point: NSPoint) {
        session.lastPoint = point
        guard let floatingView = session.floatingView, let layer = floatingView.layer else { return }
        // Real, confirmed bug found via genuine CGEvent-driven drag testing
        // with diagnostic logging: converting `targetOriginInCollectionView`
        // as a *point* here, while `floatingViewOriginalFrameInHost` (below,
        // in `createFloatingDragView`) is computed by converting the cell's
        // *rect* — `NSView.convert(_ rect:to:)` automatically corrects for a
        // flipped/non-flipped mismatch between `collectionView` (flipped)
        // and `view` (non-flipped) so `minY` always means "the visual
        // bottom edge" in the destination coordinate space, but
        // `convert(_ point:to:)` does not perform that same correction — it
        // just remaps the raw value. Mixing the two meant `dy` was always
        // off by exactly one cell's height (confirmed via logging: a purely
        // horizontal drag produced `dy == cell height` on every frame,
        // never 0), which is why the floating icon visually jumped to a
        // wildly wrong vertical position while still technically tracking
        // the cursor horizontally. Fixed by building a full rect here too,
        // so both sides of the subtraction go through the same rect-convert
        // path and agree on what `minY` means.
        let targetOriginInCollectionView = NSPoint(x: point.x - session.grabOffset.x, y: point.y - session.grabOffset.y)
        let targetRectInCollectionView = NSRect(origin: targetOriginInCollectionView, size: session.originalFrame.size)
        let host = session.floatingViewHost ?? view
        let targetRectInHost = collectionView.convert(targetRectInCollectionView, to: host)
        let dx = targetRectInHost.minX - session.floatingViewOriginalFrameInHost.minX
        let dy = targetRectInHost.minY - session.floatingViewOriginalFrameInHost.minY

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(dx, forKeyPath: "transform.translation.x")
        layer.setValue(dy, forKeyPath: "transform.translation.y")
        CATransaction.commit()

        // Real, confirmed report ("グループ化しようとするとアプリが逃げる
        // ような感じがしてやりにくい"): evaluating reorder and folder
        // candidates independently meant that moving toward another app to
        // group it also crossed the reorder hysteresis radius around that
        // same cell, so the target app itself got nudged aside by the
        // reorder preview right as the user tried to hover over it — the
        // thing being grabbed for kept moving. The folder zone check is now
        // evaluated first, and while the pointer is inside another app's
        // center zone, reorder candidate evaluation is skipped entirely
        // (not just gated on the folder candidate having *committed* —
        // gating this early, before the 0.5s hover delay fires, is what
        // keeps the target from being nudged in the first place).
        let folderTarget = folderZoneTarget(session: session, point: point)
        if folderTarget != nil {
            suppressReorderForFolderZone(session: session)
        } else {
            evaluateReorderCandidate(session: session, point: point)
        }
        evaluateFolderCandidate(session: session, point: point, zoneTarget: folderTarget)
        evaluateEdgeCandidate(session: session, point: point)
        updateEdgePeek(session: session, point: point)
    }

    // MARK: Live reorder preview

    private func frameForSlot(_ slot: Int) -> NSRect {
        let columns = max(model.gridSettings.columns, 1)
        let hSpacing = CGFloat(model.gridSettings.horizontalSpacing)
        let vSpacing = CGFloat(model.gridSettings.verticalSpacing)
        let margin = CGFloat(model.gridSettings.pageMargins)
        let cellSize = layout.currentCellSize
        let column = slot % columns
        let row = slot / columns
        let x = margin + CGFloat(column) * (cellSize.width + hSpacing)
        let y = margin + CGFloat(row) * (cellSize.height + vSpacing)
        return NSRect(x: x, y: y, width: cellSize.width, height: cellSize.height)
    }

    /// Real, confirmed report ("アプリを狙った位置に移動させるのがめちゃく
    /// ちゃむずい...狙った位置にアプリを置いてもそこにあるアプリが動かな
    /// かったりする"): the previous implementation found the single
    /// nearest *other item* (by dx²+dy² distance) and decided front/back
    /// purely from that item's X coordinate — a fundamentally 1D judgment
    /// bolted onto a 2D grid. Dragging straight up/down onto a different
    /// row landed on the same X-based front/back call as a same-row drag,
    /// which didn't reliably resolve to "the row the pointer is actually
    /// over." This computes the slot directly from the grid's own geometry
    /// (same `column = slot % columns; row = slot / columns` convention as
    /// `PagedGridLayout.prepare()` and `frameForSlot` below) instead of
    /// comparing to other items at all — "which cell is the pointer over,"
    /// not "which existing item is closest." The column is clamped to
    /// `0..<columns` *before* combining with the row — without that, a
    /// point past the grid's right edge would compute a raw column >=
    /// columns, which folds into the next row's slot range and silently
    /// points at a completely unrelated cell instead of "the last column
    /// of this row."
    private func insertionSlot(forPoint point: NSPoint, excluding excludedIndex: Int?) -> Int? {
        guard model.pages.indices.contains(currentPage) else { return nil }
        // One slot is freed up by the dragged item itself only while that item
        // is actually on this page. After a mid-drag page turn it isn't, so
        // every slot is occupied and the drop can legitimately land at the end
        // (`endItemDrag` already accepts `count` as a destination).
        let pageCount = model.pages[currentPage].count
        let remainingCount = excludedIndex == nil ? pageCount : max(pageCount - 1, 0)
        let columns = max(model.gridSettings.columns, 1)
        let hSpacing = CGFloat(model.gridSettings.horizontalSpacing)
        let vSpacing = CGFloat(model.gridSettings.verticalSpacing)
        let margin = CGFloat(model.gridSettings.pageMargins)
        let cellSize = layout.currentCellSize
        let colStride = max(cellSize.width + hSpacing, 1)
        let rowStride = max(cellSize.height + vSpacing, 1)

        let rawColumn = Int(floor((point.x - margin) / colStride))
        let clampedColumn = min(max(rawColumn, 0), columns - 1)
        let rawRow = max(Int(floor((point.y - margin) / rowStride)), 0)
        let slot = rawRow * columns + clampedColumn
        // Past the last real slot (pointer over trailing empty cells) rounds
        // down to "append at the end" — the row overshoot alone is absorbed
        // by this final clamp.
        return min(max(slot, 0), remainingCount)
    }

    /// Round 12 §8a, revised: real hysteresis around the *committed* slot,
    /// not just the raw cell-under-pointer answer — the pointer must move
    /// far enough from the committed slot's own center before a new
    /// candidate is even considered. Real, confirmed bug found while fixing
    /// "狙った位置にアプリを置いてもそこにあるアプリが動かない": the
    /// previous version judged this purely from `point.x` (`point.x >
    /// committedFrame.midX + threshold` / `< ... - threshold`), so a
    /// straight vertical drag onto a different row — where `point.x` barely
    /// moves — could never satisfy either condition even though `rawSlot`
    /// (from `insertionSlot`, itself now genuinely 2D) had already changed
    /// correctly. The candidate would then never commit no matter how far
    /// the pointer moved vertically. Judging by straight-line distance from
    /// the committed cell's center instead works for movement in any
    /// direction.
    private func evaluateReorderCandidate(session: ItemDragSession, point: NSPoint) {
        guard let rawSlot = insertionSlot(forPoint: point, excluding: session.sourceIndexOnCurrentPage) else { return }
        guard rawSlot != session.candidateSlot else {
            session.reorderTimer?.invalidate()
            return
        }
        let committedFrame = frameForSlot(session.candidateSlot)
        let dx = point.x - committedFrame.midX
        let dy = point.y - committedFrame.midY
        let radius = min(committedFrame.width, committedFrame.height) * Self.itemDragHysteresisFraction
        guard dx * dx + dy * dy > radius * radius else {
            session.reorderTimer?.invalidate()
            return
        }
        guard rawSlot != session.pendingRawSlot else { return }
        session.pendingRawSlot = rawSlot
        session.reorderTimer?.invalidate()
        // itemDragReorderDebounce is now 0 — the hysteresis radius above is
        // the sole anti-chatter gate; this Timer indirection (and
        // `session.reorderTimer`'s existence) is kept as-is so a future
        // tuning pass can reintroduce a nonzero debounce without touching
        // the surrounding structure.
        session.reorderTimer = Timer.scheduledTimer(withTimeInterval: Self.itemDragReorderDebounce, repeats: false) { [weak self, weak session] _ in
            Task { @MainActor [weak self, weak session] in
                // `activeItemDrag === session` matters as much as the
                // generation check: `itemDragGeneration` only advances in
                // `beginItemDrag`, so it does not invalidate anything when a
                // drag *ends*. This closure is one main-actor turn behind the
                // timer firing, and `invalidateTimers()` in `endItemDrag` can
                // only stop timers that have not fired yet — so without this,
                // a timer that fired just before mouseUp still commits into a
                // finished session. `commitPageTurnDuringDrag` already guards
                // this way; these three timers did not.
                guard let self, let session, self.activeItemDrag === session, session.generation == self.itemDragGeneration else { return }
                self.commitReorderCandidate(session: session, slot: rawSlot)
            }
        }
    }

    private func commitReorderCandidate(session: ItemDragSession, slot: Int) {
        guard slot != session.candidateSlot else { return }
        session.candidateSlot = slot
        animateReorderPreview(session: session)
    }

    /// Spec 8.2: remaining items spring to their preview slot — no fade, no
    /// rotation, uniform timing regardless of row. Only the *visual*
    /// arrangement changes here (via each live cell view's own layer
    /// transform); `model.pages` itself is untouched until the drop
    /// actually commits in `endItemDrag`.
    private func animateReorderPreview(session: ItemDragSession) {
        guard model.pages.indices.contains(currentPage) else { return }
        let items = model.pages[currentPage]
        var naturalPos = 0
        for originalIndex in items.indices where originalIndex != session.sourceIndexOnCurrentPage {
            let previewSlot = naturalPos < session.candidateSlot ? naturalPos : naturalPos + 1
            naturalPos += 1
            guard let cell = collectionView.item(at: IndexPath(item: originalIndex, section: 0)) as? GridCellItem,
                  let originalFrame = layout.layoutAttributesForItem(at: IndexPath(item: originalIndex, section: 0))?.frame,
                  let layer = cell.view.layer else { continue }
            let targetFrame = frameForSlot(previewSlot)
            // Real, confirmed report ("アプリを狙った位置に移動させるのが
            // めちゃくちゃむずい"): the shared default (damping 0.86,
            // response 0.24) reads fine for a settle/revert landing but
            // adds one more layer of lag on top of the hysteresis/debounce
            // changes above for a "make way" nudge during live dragging.
            // Snappier, less bouncy values here only — `settleFloatingView`
            // and `revertItemDrag` below keep calling this with no damping/
            // response arguments, so their behavior is untouched.
            animateLayerTranslation(layer, toX: targetFrame.minX - originalFrame.minX, toY: targetFrame.minY - originalFrame.minY, damping: 0.90, response: 0.16)
        }
    }

    /// Round 12 §8c: reads the layer's current presentation-value (already
    /// correct for position-continuity on a mid-flight re-target — no
    /// "jump") *and* now also approximates its current velocity by
    /// comparing against the value recorded at the previous re-target on
    /// this exact layer/keypath pair, handing that off as the new spring's
    /// `initialVelocity` so a re-targeted reorder-preview shift doesn't
    /// visually hard-cut to a standstill before easing toward the new slot
    /// (apple-design §3's interruptibility rule). This is a coarse,
    /// event-to-event average, not true instantaneous release velocity —
    /// appropriate given every caller here is a discrete, event-driven
    /// re-target (a candidate-slot change), not a continuously-scrubbing
    /// gesture; see `commitPageTurnDuringDrag` for the other velocity-
    /// handoff case, which reuses the edge-peek's own last-known offset/time
    /// instead of this generic per-layer cache.
    private func animateLayerTranslation(_ layer: CALayer, toX dx: CGFloat, toY dy: CGFloat, damping: CGFloat = 0.86, response: CGFloat = 0.24) {
        let presentationLayer = layer.presentation() ?? layer
        let currentX = (presentationLayer.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
        let currentY = (presentationLayer.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
        let now = CACurrentMediaTime()
        let key = ObjectIdentifier(layer)
        let previous = lastAnimatedValueByLayer[key]
        let velocityX = Self.estimateVelocity(from: previous?.x, at: previous?.xTime, to: currentX, at: now)
        let velocityY = Self.estimateVelocity(from: previous?.y, at: previous?.yTime, to: currentY, at: now)
        lastAnimatedValueByLayer[key] = (currentX, now, currentY, now)

        layer.setValue(dx, forKeyPath: "transform.translation.x")
        layer.setValue(dy, forKeyPath: "transform.translation.y")
        // `CASpringAnimation.initialVelocity` wants a value relative to the
        // distance being traveled (same convention `endPageDrag`'s own
        // `relativeVelocity` already uses for the trackpad-swipe path) —
        // zero when there's no distance left to travel, to avoid dividing
        // by a near-zero denominator.
        let relativeVX = abs(dx - currentX) > 0.5 ? velocityX / (dx - currentX) : 0
        let relativeVY = abs(dy - currentY) > 0.5 ? velocityY / (dy - currentY) : 0
        layer.add(Self.springAnimation(keyPath: "transform.translation.x", from: currentX, to: dx, damping: damping, response: response, initialVelocity: relativeVX), forKey: "reorderX")
        layer.add(Self.springAnimation(keyPath: "transform.translation.y", from: currentY, to: dy, damping: damping, response: response, initialVelocity: relativeVY), forKey: "reorderY")
    }

    private static func estimateVelocity(from previousValue: CGFloat?, at previousTime: CFTimeInterval?, to currentValue: CGFloat, at currentTime: CFTimeInterval) -> CGFloat {
        guard let previousValue, let previousTime, currentTime - previousTime > 0.001, currentTime - previousTime < 1.0 else { return 0 }
        return (currentValue - previousValue) / CGFloat(currentTime - previousTime)
    }

    private func resetItemTransform(_ view: NSView) {
        guard let layer = view.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    // MARK: Folder-candidate detection

    /// Spec 11.1: only apps can be a folder-creation *source* onto another
    /// item — dragging a folder doesn't nest folders, matching
    /// `GridModel.createOrJoinFolder`'s existing app+app/app+folder-only
    /// semantics (unchanged by this rewrite). Extracted out of
    /// `evaluateFolderCandidate` so `updateItemDrag` can also consult it
    /// *before* evaluating the reorder candidate — see that method's doc
    /// comment for why the ordering matters.
    private func folderZoneTarget(session: ItemDragSession, point: NSPoint) -> Int? {
        guard case .app = session.draggedItem, model.pages.indices.contains(currentPage) else { return nil }
        let items = model.pages[currentPage]
        for index in items.indices where index != session.sourceIndexOnCurrentPage {
            guard let frame = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { continue }
            let inset = min(frame.width, frame.height) * Self.itemDragFolderZoneInset
            let centerZone = frame.insetBy(dx: inset, dy: inset)
            if centerZone.contains(point) { return index }
        }
        return nil
    }

    private func evaluateFolderCandidate(session: ItemDragSession, point: NSPoint, zoneTarget: Int?) {
        guard zoneTarget != session.pendingRawFolderCandidateIndex else { return }
        session.pendingRawFolderCandidateIndex = zoneTarget
        session.folderTimer?.invalidate()
        guard let zoneTarget else {
            clearFolderCandidate(session: session)
            return
        }
        // Real, confirmed report ("グループ化...ui的にも操作的にもわかり
        // やすく"): the raw zone entry (before the hover delay commits)
        // now gets its own immediate feedback — a visible drop-zone ring
        // with a progress sweep timed to the hover delay, and the dragged
        // icon itself pulling inward — instead of nothing changing until
        // `commitFolderCandidate` fires 0.5s later.
        showFolderZoneIndicator(session: session, targetIndex: zoneTarget)
        beginFloatingViewFolderPull(session: session, engaged: true)
        session.folderTimer = Timer.scheduledTimer(withTimeInterval: Self.itemDragFolderHoverDelay, repeats: false) { [weak self, weak session] _ in
            Task { @MainActor [weak self, weak session] in
                // See `evaluateReorderCandidate`'s guard for why the session
                // identity check is required in addition to the generation.
                // Without it this could scale a cell to 1.06 on behalf of a
                // finished drag, with nothing left to clear the highlight.
                guard let self, let session, self.activeItemDrag === session, session.generation == self.itemDragGeneration else { return }
                self.commitFolderCandidate(session: session, index: zoneTarget)
            }
        }
    }

    private func commitFolderCandidate(session: ItemDragSession, index: Int) {
        guard session.folderCandidateOriginalIndex != index else { return }
        clearFolderCandidateHighlight(session: session)
        session.folderCandidateOriginalIndex = index
        // The ring's job (showing "not yet committed, hover to confirm")
        // is done — the target's own 1.06x growth below takes over as the
        // "committed" signal.
        clearFolderZoneIndicator(session: session)
        DiagnosticsLog.grid.notice("commitFolderCandidate: index \(index, privacy: .public)")
        guard let cell = collectionView.item(at: IndexPath(item: index, section: 0)) as? GridCellItem, let layer = cell.view.layer else { return }
        layer.add(Self.springAnimation(keyPath: "transform.scale", from: 1.0, to: 1.06, damping: 0.82, response: 0.2), forKey: "folderCandidate")
        // Keypath assignment, not a raw `layer.transform = ...` assignment
        // — this file's consistent convention (see `updateItemDrag`'s doc
        // comment) is translation via `transform.translation.x/y` and
        // scale via `transform.scale`, never a bare `.transform` overwrite,
        // so scale changes here compose cleanly with any translation this
        // same layer might carry.
        layer.setValue(1.06, forKeyPath: "transform.scale")
    }

    private func clearFolderCandidate(session: ItemDragSession) {
        session.pendingRawFolderCandidateIndex = nil
        session.folderTimer?.invalidate()
        clearFolderCandidateHighlight(session: session)
        clearFolderZoneIndicator(session: session)
        beginFloatingViewFolderPull(session: session, engaged: false)
    }

    /// Real, confirmed report ("グループ化しようとするとアプリが逃げる"):
    /// called from `updateItemDrag` whenever the pointer is inside another
    /// app's folder drop zone, *before* the 0.5s hover delay confirms a
    /// folder candidate — pins the reorder preview back to its identity
    /// state (every item at its own natural slot, zero visual
    /// displacement) so the target app being hovered over never gets
    /// nudged aside by a reorder candidate change while the user is trying
    /// to hold the pointer over it.
    private func suppressReorderForFolderZone(session: ItemDragSession) {
        session.reorderTimer?.invalidate()
        // Keeps `evaluateReorderCandidate`'s "same as last pending raw slot"
        // guard from swallowing a real re-evaluation once the pointer
        // leaves the folder zone again.
        // "Identity" means the dragged item's own slot on the page in view. On
        // a page it isn't part of there is no such slot, so the closest thing
        // to leaving the layout untouched is the end of the page.
        let identitySlot: Int
        if let indexOnCurrentPage = session.sourceIndexOnCurrentPage {
            identitySlot = indexOnCurrentPage
        } else if model.pages.indices.contains(currentPage) {
            identitySlot = model.pages[currentPage].count
        } else {
            identitySlot = 0
        }
        session.pendingRawSlot = identitySlot
        guard session.candidateSlot != identitySlot else { return }
        commitReorderCandidate(session: session, slot: identitySlot)
    }

    private func clearFolderCandidateHighlight(session: ItemDragSession) {
        guard let index = session.folderCandidateOriginalIndex else { return }
        session.folderCandidateOriginalIndex = nil
        guard let cell = collectionView.item(at: IndexPath(item: index, section: 0)) as? GridCellItem else { return }
        resetItemTransform(cell.view)
    }

    /// Real, confirmed report ("グループ化...UI的にも操作的にもわかりや
    /// すく"): the dragged icon itself never changed when it entered a
    /// folder drop zone — only the far-away target cell grew slightly.
    /// Since the user's eyes are usually on the icon they're actually
    /// holding, that made the "this will make a folder" signal easy to
    /// miss. Shrinking the floating icon toward the growing target (0.92x
    /// vs. the target's 1.06x, same damping/response so both feel like
    /// one gesture) gives a visible cue right where the user is looking.
    /// Starts from the layer's current presentation value (same technique
    /// `animateLayerTranslation` already uses) so this reads smoothly even
    /// if the initial 1.0→1.06 lift spring from `createFloatingDragView`
    /// hasn't finished yet.
    private func beginFloatingViewFolderPull(session: ItemDragSession, engaged: Bool) {
        guard let layer = session.floatingView?.layer else { return }
        let liftScale: CGFloat = 1.06
        let pullScale: CGFloat = 0.92
        let targetScale = engaged ? pullScale : liftScale
        let currentScale = (layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? (engaged ? liftScale : pullScale)
        guard abs(currentScale - targetScale) > 0.001 else { return }
        layer.setValue(targetScale, forKeyPath: "transform.scale")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        layer.add(Self.springAnimation(keyPath: "transform.scale", from: currentScale, to: targetScale, damping: 0.82, response: 0.2), forKey: "folderPull")
    }

    /// Real, confirmed report ("フォルダ制作のUiがひどすぎる長方形だし
    /// iphoneのような美しくわかりやすい素晴らしいデザインにして"): this
    /// used to be sized from the *whole grid slot* rect (icon + label band
    /// + padding, via `layout.layoutAttributesForItem`), which read as an
    /// oversized rectangle instead of a ring around the icon. Now built
    /// from `GridCellItem.iconFrame` (see that property's doc comment) —
    /// a rounded square a little larger than the icon itself, matching how
    /// iOS's own folder-creation highlight wraps just the icon, not the
    /// name label underneath it. `folderZoneTarget`'s hit-test zone (still
    /// the full cell's center 60%) is intentionally left wider than what's
    /// drawn here — iOS does the same: the hit region is generous, the
    /// visual feedback is tight to the icon.
    private func showFolderZoneIndicator(session: ItemDragSession, targetIndex: Int) {
        clearFolderZoneIndicator(session: session, animated: false)
        guard let cell = collectionView.item(at: IndexPath(item: targetIndex, section: 0)) as? GridCellItem else { return }
        let host = session.floatingViewHost ?? view
        host.wantsLayer = true
        host.clipsToBounds = false
        host.layer?.masksToBounds = false
        let iconFrameInHost = cell.view.convert(cell.iconFrame, to: host)
        guard iconFrameInHost.width > 0, iconFrameInHost.height > 0 else { return }

        let indicatorSize = iconFrameInHost.width * Self.itemDragFolderZoneIndicatorScale
        let zoneRectInHost = NSRect(
            x: iconFrameInHost.midX - indicatorSize / 2,
            y: iconFrameInHost.midY - indicatorSize / 2,
            width: indicatorSize,
            height: indicatorSize
        )

        let indicator = NonInteractiveImageView(frame: zoneRectInHost)
        indicator.wantsLayer = true
        indicator.clipsToBounds = false
        indicator.layer?.masksToBounds = false
        let cornerRadius = indicatorSize * Self.itemDragFolderZoneIndicatorCornerRatio
        indicator.layer?.cornerRadius = cornerRadius
        indicator.layer?.cornerCurve = .continuous
        // A soft filled backdrop, not a bordered box — iOS's own folder
        // highlight reads as "a plate the icon rests on," not an outline.
        // Stays within this grid's existing white-alpha vocabulary
        // (`applySelection` uses 0.28 for its own border) — bumped above
        // the previous 0.06 fill since this indicator now covers a much
        // smaller area and needs to read clearly over arbitrary wallpaper.
        indicator.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        indicator.layer?.borderWidth = 1
        indicator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        indicator.layer?.opacity = 0
        if let floatingView = session.floatingView, floatingView.superview === host {
            host.addSubview(indicator, positioned: .below, relativeTo: floatingView)
        } else {
            host.addSubview(indicator)
        }
        session.folderZoneIndicatorView = indicator

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let progressRing = CAShapeLayer()
        let ringInset: CGFloat = 1
        progressRing.path = CGPath(
            roundedRect: indicator.bounds.insetBy(dx: ringInset, dy: ringInset),
            cornerWidth: cornerRadius - ringInset,
            cornerHeight: cornerRadius - ringInset,
            transform: nil
        )
        progressRing.fillColor = NSColor.clear.cgColor
        progressRing.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        progressRing.lineWidth = 1.5
        progressRing.strokeEnd = reduceMotion ? 1 : 0
        indicator.layer?.addSublayer(progressRing)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.layer?.opacity = 1
        CATransaction.commit()
        indicator.layer?.add(Self.springAnimation(keyPath: "opacity", from: 0, to: 1, damping: 1.0, response: 0.12), forKey: "zoneFadeIn")

        guard !reduceMotion else { return }
        let sweep = CABasicAnimation(keyPath: "strokeEnd")
        sweep.fromValue = 0
        sweep.toValue = 1
        sweep.duration = Self.itemDragFolderHoverDelay
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.isRemovedOnCompletion = false
        sweep.fillMode = .forwards
        progressRing.strokeEnd = 1
        progressRing.add(sweep, forKey: "folderHoverProgress")
    }

    private func clearFolderZoneIndicator(session: ItemDragSession, animated: Bool = true) {
        guard let indicator = session.folderZoneIndicatorView else { return }
        session.folderZoneIndicatorView = nil
        guard animated else {
            indicator.removeFromSuperview()
            return
        }
        let currentOpacity = indicator.layer?.presentation()?.opacity ?? 1
        CATransaction.begin()
        CATransaction.setCompletionBlock { indicator.removeFromSuperview() }
        indicator.layer?.add(Self.springAnimation(keyPath: "opacity", from: CGFloat(currentOpacity), to: 0, damping: 1.0, response: 0.1), forKey: "zoneFadeOut")
        indicator.layer?.opacity = 0
        CATransaction.commit()
    }

    // MARK: Page-edge turning while dragging

    /// Spec 9: holding the dragged icon near a page edge previews and then
    /// commits a page turn, while the dragged icon itself stays fixed under
    /// the pointer (it's a floating overlay on the window content host,
    /// independent of the collection view being transformed) — only the
    /// grid/background/page
    /// indicator move, matching "掴んだアイコンまでページと一緒に流しては
    /// いけない". First/last page gets a small resistance nudge instead
    /// (spec 10), reusing the page-drag machinery's own `rubberBand` helper.
    private func evaluateEdgeCandidate(session: ItemDragSession, point: NSPoint) {
        let width = max(collectionView.bounds.width, 1)
        var direction = 0
        if point.x < Self.itemDragEdgeZoneWidth, currentPage > 0 {
            direction = -1
        } else if point.x > width - Self.itemDragEdgeZoneWidth, currentPage < model.pages.count - 1 {
            direction = 1
        }

        guard direction != session.edgeDirection else { return }
        session.edgeDirection = direction
        session.edgeTimer?.invalidate()
        guard direction != 0 else { return }
        let committedDirection = direction
        session.edgeTimer = Timer.scheduledTimer(withTimeInterval: Self.itemDragEdgeHoverDelay, repeats: false) { [weak self, weak session] _ in
            Task { @MainActor [weak self, weak session] in
                // See `evaluateReorderCandidate`'s guard for why session
                // identity is checked alongside the generation.
                guard let self,
                      let session,
                      self.activeItemDrag === session,
                      session.generation == self.itemDragGeneration,
                      session.edgeDirection == committedDirection
                else { return }
                self.commitPageTurnDuringDrag(session: session, direction: committedDirection)
            }
        }
    }

    /// Round 12 §8b: continuous, non-animated (per apple-design §1 —
    /// feedback lives *during* the interaction, not just at its end) preview
    /// of the incoming page while the pointer dwells in an edge zone, before
    /// `evaluateEdgeCandidate`'s dwell timer actually commits the turn.
    /// Reuses `renderPageSnapshot` — the same real-`NSWindow`-hosted
    /// offscreen renderer already proven safe for the trackpad-swipe page-
    /// turn's own neighbor snapshot (fixed twice in this file's history:
    /// once for a permanently-stuck-hidden live grid, once for a fully-
    /// transparent bitmap from a collection view that was never actually
    /// hosted in a real window) — rather than inventing a second snapshot
    /// mechanism for this one.
    private func updateEdgePeek(session: ItemDragSession, point: NSPoint) {
        let width = max(collectionView.bounds.width, 1)
        let zone = Self.itemDragEdgeZoneWidth
        // `penetration`: raw distance (0...zone) the pointer has pushed past
        // the edge zone's own outer boundary — not yet normalized to 0...1.
        // Fed through `rubberBand` below instead of a linear proportion (see
        // `itemDragEdgePeekResistanceDimension`'s doc comment for why).
        var penetration: CGFloat = 0
        var direction = 0
        if point.x < zone, currentPage > 0 {
            direction = -1
            penetration = zone - point.x
        } else if point.x > width - zone, currentPage < model.pages.count - 1 {
            direction = 1
            penetration = point.x - (width - zone)
        }
        guard direction != 0 else {
            clearEdgePeek(session: session)
            return
        }

        if session.edgePeekImageView == nil {
            prefetchAdjacentPageIcons(including: currentPage + direction)
            guard let image = renderPageSnapshot(forPage: currentPage + direction, size: collectionView.bounds.size) else { return }
            let xOffset = direction > 0 ? width : -width
            // Same parent/frame convention as the trackpad-swipe path's own
            // `dragNeighborImageView` (`updatePageDrag`) — added to `view`
            // (not `collectionView`'s actual superview, the scroll view's
            // internal clip view, which has its own scrolled coordinate
            // space) positioned just above `scrollView`, sized from
            // `scrollView.frame` rather than `collectionView.frame`.
            let imageView = NSImageView(frame: NSRect(
                x: scrollView.frame.origin.x + xOffset,
                y: scrollView.frame.origin.y,
                width: scrollView.frame.width,
                height: scrollView.frame.height
            ))
            imageView.image = image
            imageView.imageScaling = .scaleNone
            imageView.wantsLayer = true
            view.addSubview(imageView, positioned: .above, relativeTo: scrollView)
            session.edgePeekImageView = imageView
        }

        // Real, confirmed report ("ページ端についてその先へ無理や進もう
        // とした時に起きるアニメーションが過剰すぎる"): reuses the same
        // rubber-band resistance formula the trackpad page-swipe already
        // uses at its own edges — overshoot-proportional resistance
        // instead of the old linear `proximity * 30` ramp that kept
        // growing the harder the pointer pushed.
        let dampedOffset = Self.rubberBand(penetration, dimension: Self.itemDragEdgePeekResistanceDimension)
        let previewOffset = -dampedOffset * CGFloat(direction)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        collectionView.wantsLayer = true
        collectionView.layer?.setValue(previewOffset, forKeyPath: "transform.translation.x")
        let peekOffset = previewOffset + (direction > 0 ? width : -width)
        session.edgePeekImageView?.layer?.setValue(peekOffset, forKeyPath: "transform.translation.x")
        CATransaction.commit()
        session.lastPeekOffset = previewOffset
        session.lastPeekTime = CACurrentMediaTime()
    }

    /// Springs the peek back out (not an instant snap) so backing out of the
    /// edge zone before the dwell timer fires doesn't read as an abrupt cut
    /// — this is deliberately the *only* place a bare peek offset is reset
    /// without an accompanying commit, so it needs its own settle animation
    /// Springs the peek back out (not an instant snap) so backing out of the
    /// edge zone before the dwell timer fires doesn't read as an abrupt cut
    /// — this is deliberately the *only* place a bare peek offset is reset
    /// without an accompanying commit, so it needs its own settle animation
    /// (the page-turn commit path in `commitPageTurnDuringDrag` handles its
    /// own transition instead of going through this).
    private func clearEdgePeek(session: ItemDragSession) {
        guard let peekImageView = session.edgePeekImageView else { return }
        let lastOffset = session.lastPeekOffset ?? 0
        collectionView.layer?.add(Self.springAnimation(keyPath: "transform.translation.x", from: lastOffset, to: 0, damping: 0.98, response: 0.20), forKey: "edgePeekRevert")
        collectionView.layer?.setValue(0, forKeyPath: "transform.translation.x")
        peekImageView.removeFromSuperview()
        session.edgePeekImageView = nil
        session.lastPeekOffset = nil
        session.lastPeekTime = nil
    }


    /// (the page-turn commit path in `commitPageTurnDuringDrag` handles its

    private func commitPageTurnDuringDrag(session: ItemDragSession, direction: Int) {
        let targetPage = currentPage + direction
        guard model.pages.indices.contains(targetPage) else { return }
        DiagnosticsLog.grid.notice("commitPageTurnDuringDrag: page \(self.currentPage, privacy: .public) -> \(targetPage, privacy: .public)")

        // Settle any in-flight reorder preview on the page being left, then
        // move to the new page as a fresh drag target (its own items become
        // the new "remaining" set — the dragged item conceptually floats
        // above whichever page is current, matching the spec's "screen
        // coordinates are re-converted to page-local coordinates, candidate
        // re-evaluated" sequence in 9.4).
        for item in collectionView.visibleItems() { resetItemTransform(item.view) }

        // Round 12 §8c: hand off the peek's own in-flight velocity to the
        // commit spring, rather than starting fresh from zero — the peek
        // (§8b) is very likely still easing when the dwell timer fires this,
        // and a zero-velocity restart here is exactly the "hard cut" apple-
        // design §3 warns against.
        let width = max(collectionView.bounds.width, 1)
        let offset: CGFloat = direction > 0 ? -width : width
        let presentationX = (collectionView.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
        let rawVelocity = Self.estimateVelocity(from: session.lastPeekOffset, at: session.lastPeekTime, to: presentationX, at: CACurrentMediaTime())
        let boundedVelocity = min(max(rawVelocity, -1600), 1600)
        let relativeVelocity = abs(offset - presentationX) > 1 ? boundedVelocity / (offset - presentationX) : 0
        let peekImageView = session.edgePeekImageView
        session.edgePeekImageView = nil // this function now owns the transition, not clearEdgePeek
        session.lastPeekOffset = nil
        session.lastPeekTime = nil

        collectionView.wantsLayer = true
        let spring = Self.springAnimation(keyPath: "transform.translation.x", from: presentationX, to: offset, damping: 0.98, response: 0.30, initialVelocity: relativeVelocity)
        collectionView.layer?.add(spring, forKey: "itemDragPageTurnOut")
        collectionView.layer?.setValue(offset, forKeyPath: "transform.translation.x")
        // The peek image (if one was already showing) rides out at the same
        // damping/response/velocity — same motion "feel" — rather than
        // being torn down abruptly. It needs its own `CASpringAnimation`
        // instance (not the same one reused) since it's sitting a constant
        // `±width` away from the collection view and therefore has its own
        // `from`/`to` values, but velocity is a rate and is unaffected by
        // that constant offset, so handing off the exact same
        // `relativeVelocity` to both is correct.
        if let peekImageView {
            let peekOffsetConstant: CGFloat = direction > 0 ? width : -width
            let peekCurrentX = (peekImageView.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? (presentationX + peekOffsetConstant)
            let peekTarget = offset + peekOffsetConstant
            let peekSpring = Self.springAnimation(keyPath: "transform.translation.x", from: peekCurrentX, to: peekTarget, damping: 0.98, response: 0.30, initialVelocity: relativeVelocity)
            peekImageView.layer?.add(peekSpring, forKey: "itemDragPageTurnOut")
            peekImageView.layer?.setValue(peekTarget, forKeyPath: "transform.translation.x")
        }

        let settleDuration = min(max(spring.settlingDuration, 0.12), 0.55)
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDuration) { [weak self] in
            Task { @MainActor in
                // Torn down unconditionally, even if the guard below bails
                // (stale/superseded drag) — this function already took
                // ownership of `peekImageView` from `session` above, so
                // nothing else will clean it up if this early-returns.
                peekImageView?.removeFromSuperview()
                guard let self, self.activeItemDrag === session, session.generation == self.itemDragGeneration else { return }
                self.currentPage = targetPage
                self.layout.settings = self.model.gridSettings
                self.layout.invalidateLayout()
                self.collectionView.collectionViewLayout?.invalidateLayout()
                self.collectionView.reloadData()
                self.collectionView.layoutSubtreeIfNeeded()
                self.collectionView.displayIfNeeded()

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.collectionView.layer?.setValue(0, forKeyPath: "transform.translation.x")
                CATransaction.commit()
                self.pageControl.currentPage = targetPage
                self.prefetchAdjacentPageIcons()

                session.pendingRawSlot = -1
                session.candidateSlot = self.model.pages.indices.contains(targetPage) ? self.model.pages[targetPage].count : 0
                session.edgeDirection = 0
                // The dragged item lives on its origin page, not this one, so
                // nothing on the new page should be excluded from the reorder
                // preview or from folder targeting. See the property's own doc
                // comment for the three concrete misbehaviours this prevents.
                session.sourceIndexOnCurrentPage = nil
                // Real, confirmed latent bug (found while wiring up the
                // folder zone indicator, not user-reported): this function
                // already resets pendingRawSlot/candidateSlot/edgeDirection
                // for the new page, but never reset the folder-candidate
                // state — a folder candidate committed on the page being
                // left would survive the page turn pointing at a now-
                // unrelated index on the new page, and endItemDrag could
                // call createOrJoinFolder against the wrong app. Same
                // symmetric reset, added here for the same reason.
                session.folderTimer?.invalidate()
                session.pendingRawFolderCandidateIndex = nil
                self.clearFolderCandidateHighlight(session: session)
                self.clearFolderZoneIndicator(session: session, animated: false)
                self.updateItemDrag(session: session, point: session.lastPoint)
            }
        }
    }

    // MARK: Drop / settle / cancel

    private func endItemDrag(session: ItemDragSession) {
        disarmItemDragSafetyNet()
        session.invalidateTimers()
        activeItemDrag = nil
        clearEdgePeek(session: session)
        clearFolderZoneIndicator(session: session, animated: false)
        lastAnimatedValueByLayer.removeAll()

        let hasFolderTarget = session.folderCandidateOriginalIndex != nil
        DiagnosticsLog.grid.notice("endItemDrag: committing reorder to slot \(session.candidateSlot, privacy: .public), folderTarget=\(hasFolderTarget, privacy: .public)")

        // Real, confirmed bug: resetting cells' transforms *after*
        // stopWobble() removed their one active, continuous animation left
        // the reset's own bare (animation-disabled) transform write with
        // nothing to piggyback a repaint on — cells could stay visually
        // stuck at their last reorder-preview offset even though their
        // model transform (and therefore hit-testing, which AppKit always
        // computes from untransformed layout) was already back to identity.
        // That mismatch is what made clicks resolve to the wrong item
        // ("なぜか上のだけ開く"). Resetting first, while wobble is still
        // active, ensures the reset itself gets composited.
        for item in collectionView.visibleItems() { resetItemTransform(item.view) }
        stopWobble()

        if let folderTargetIndex = session.folderCandidateOriginalIndex {
            model.createOrJoinFolder(
                sourcePage: session.sourcePage,
                sourceIndex: session.sourceOriginalIndex,
                destinationPage: currentPage,
                destinationIndex: folderTargetIndex
            )
        } else {
            model.moveItem(
                fromPage: session.sourcePage,
                fromIndex: session.sourceOriginalIndex,
                toPage: currentPage,
                toIndex: min(session.candidateSlot, model.pages.indices.contains(currentPage) ? model.pages[currentPage].count : 0)
            )
        }
        Task { await model.save() }

        settleFloatingView(session: session)
    }

    /// Spec 13.1: the floating icon springs to its final cell before being
    /// cleaned up, so the drop reads as "landing," not an abrupt swap.
    /// Spec 13.1: springs to the final cell — like `updateItemDrag`, this
    /// drives the move purely via `transform.translation.x/y` relative to
    /// the floating view's never-reassigned `.frame`, not by touching
    /// `.frame` itself (see that method's doc comment for why mixing the
    /// two was a real, confirmed bug).
    private func settleFloatingView(session: ItemDragSession) {
        guard let floatingView = session.floatingView, let layer = floatingView.layer else {
            collectionView.reloadData()
            return
        }
        collectionView.reloadData()
        collectionView.layoutSubtreeIfNeeded()

        let targetOriginalIndex = min(session.candidateSlot, model.pages.indices.contains(currentPage) ? max(model.pages[currentPage].count - 1, 0) : 0)
        let targetFrame = layout.layoutAttributesForItem(at: IndexPath(item: targetOriginalIndex, section: 0))?.frame ?? session.originalFrame
        let host = session.floatingViewHost ?? view
        let targetFrameInHost = collectionView.convert(targetFrame, to: host)
        let dx = targetFrameInHost.minX - session.floatingViewOriginalFrameInHost.minX
        let dy = targetFrameInHost.minY - session.floatingViewOriginalFrameInHost.minY

        animateLayerTranslation(layer, toX: dx, toY: dy)
        // Real, confirmed report ("グループ化...アプリが逃げる"): reads the
        // layer's current presentation value instead of assuming 1.06 —
        // while hovering over a folder target this layer may have been
        // pulled to 0.92 by `beginFloatingViewFolderPull`, and settling
        // from a hardcoded 1.06 would visibly jump backward before easing
        // to 1.0.
        let currentScale = (layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1.06
        layer.setValue(1.0, forKeyPath: "transform.scale")
        layer.add(Self.springAnimation(keyPath: "transform.scale", from: currentScale, to: 1.0, damping: 1.0, response: 0.18), forKey: "settleScale")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            Task { @MainActor in
                floatingView.removeFromSuperview()
                session.floatingViewHost = nil
                self?.collectionView.item(at: IndexPath(item: targetOriginalIndex, section: 0))?.view.layer?.opacity = 1
                self?.collectionView.reloadData()
            }
        }
    }

    /// Spec 13.2/13.3: invalid drop or cancel — spring back to the original
    /// cell (same transform-only approach as `settleFloatingView`), undo
    /// any reorder preview, no model mutation.
    private func revertItemDrag(session: ItemDragSession) {
        disarmItemDragSafetyNet()
        session.invalidateTimers()
        activeItemDrag = nil
        clearEdgePeek(session: session)
        clearFolderZoneIndicator(session: session, animated: false)
        lastAnimatedValueByLayer.removeAll()
        // See endItemDrag's doc comment: reset before stopWobble(), not
        // after, so the reset's own transform write still has an active
        // animation on these layers to piggyback its repaint on.
        clearFolderCandidateHighlight(session: session)
        for item in collectionView.visibleItems() { resetItemTransform(item.view) }
        stopWobble()

        guard let floatingView = session.floatingView, let layer = floatingView.layer else { return }
        animateLayerTranslation(layer, toX: 0, toY: 0)
        // See settleFloatingView's doc comment — same "may have been pulled
        // to 0.92 by a folder hover" reasoning applies to a cancel/revert.
        let currentScale = (layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1.06
        layer.setValue(1.0, forKeyPath: "transform.scale")
        layer.add(Self.springAnimation(keyPath: "transform.scale", from: currentScale, to: 1.0, damping: 1.0, response: 0.2), forKey: "revertScale")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            Task { @MainActor in
                floatingView.removeFromSuperview()
                session.floatingViewHost = nil
            }
        }
        collectionView.item(at: IndexPath(item: session.sourceOriginalIndex, section: 0))?.view.layer?.opacity = 1
    }

    // MARK: Jiggle mode
    //
    // Real Launchpad/iOS home-screen convention: starting to drag any icon
    // makes every icon on screen wobble, signaling "you're rearranging now."
    // Scoped to just the duration of one item drag (see the section above)
    // — this project has no "done editing" affordance (no delete badges, no
    // explicit exit button) for a persistent post-drag edit mode the way
    // real Launchpad has, so extending the wobble beyond one drag's
    // lifetime wouldn't have anything meaningful to attach to.

    private func startWobble() {
        for item in collectionView.visibleItems() {
            guard let layer = item.view.layer else { continue }
            // Confirmed too fast/large by the user ("揺れが不気味") at the
            // original 0.035rad/0.12s — nearly halved the angle and roughly
            // doubled the cycle so it reads as a calm sway rather than a
            // frantic shake.
            let angle: CGFloat = 0.016 // ~0.9°, calmer
            let anim = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            anim.values = [-angle, angle, -angle]
            anim.duration = 0.22 + Double.random(in: -0.01...0.01)
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            // A random per-cell begin time (rather than a fixed offset) is
            // what desyncs the wobble across cells — repeatCount == .infinity
            // makes the animation strictly periodic, so a different start
            // phase persists as a different phase forever, matching real
            // Launchpad's slightly-uncoordinated wobble instead of every
            // icon shaking in perfect unison.
            anim.beginTime = CACurrentMediaTime() + Double.random(in: 0..<anim.duration)
            layer.add(anim, forKey: "wobble")
        }
    }

    private func stopWobble() {
        for item in collectionView.visibleItems() {
            item.view.layer?.removeAnimation(forKey: "wobble")
        }
    }
}

/// A minimal, throwaway `NSCollectionViewDataSource` for rendering one
/// page's worth of cells into an offscreen snapshot (see
/// `GridViewController.renderPageSnapshot(forPage:size:)`) — deliberately
/// independent of `GridViewController`'s own data-source conformance
/// (which always reads `currentPage`) so building a snapshot of an
/// *adjacent* page never has to temporarily perturb the live grid's state.
private final class SnapshotDataSource: NSObject, NSCollectionViewDataSource {
    private let items: [LayoutItem]
    private let model: GridModel
    private let iconCache: IconCache
    private let itemIdentifier: NSUserInterfaceItemIdentifier
    private let iconSize: Double
    private let visualScale: Double

    init(items: [LayoutItem], model: GridModel, iconCache: IconCache, itemIdentifier: NSUserInterfaceItemIdentifier, iconSize: Double, visualScale: Double = 1) {
        self.items = items
        self.model = model
        self.iconCache = iconCache
        self.itemIdentifier = itemIdentifier
        self.iconSize = iconSize
        self.visualScale = visualScale
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let cell = collectionView.makeItem(withIdentifier: itemIdentifier, for: indexPath) as? GridCellItem,
              items.indices.contains(indexPath.item) else {
            return NSCollectionViewItem()
        }
        switch items[indexPath.item] {
        case .app(let id):
            guard let record = model.record(for: id) else { return cell }
            let icon = iconCache.cachedIconIfAvailable(for: record) ?? NSImage()
            let displayName = model.displayName(for: record)
            cell.configureAsApp(record: record, icon: icon, isSelected: false, iconSize: iconSize, visualScale: visualScale, displayName: displayName)
        case .folder(let folderID):
            let folder = model.folders[folderID]
            let name = folder?.name ?? L10n.defaultFolderName
            // Synchronous, cache-only icons: this data source only renders
            // one offscreen snapshot bitmap with no async work in between
            // (see this type's doc comment and `IconCache.icon`'s
            // `cachedIconIfAvailable` counterpart used for the app case
            // above) — an async fetch here would resolve after the
            // snapshot's already been captured and the temp collection view
            // torn down.
            let records: [ApplicationRecord] = folder?.pages.flatMap { $0 }.compactMap { item in
                guard case .app(let id) = item else { return nil }
                return model.record(for: id)
            } ?? []
            let icons = records.prefix(9).compactMap { iconCache.cachedIconIfAvailable(for: $0) }
            cell.configureAsFolder(name: name, isSelected: false, iconSize: iconSize, visualScale: visualScale, icons: icons, requestKey: "folder:\(folderID.value)")
        }
        return cell
    }
}

/// Full-bounds dimming backdrop for the opened-folder overlay (see
/// `GridViewController.openFolder`'s doc comment). Clicking anywhere on
/// the backdrop itself dismisses — clicks on the folder panel (a subview
/// added on top) never reach here at all, since AppKit hit-tests subviews
/// before their parent, so the panel's own click-to-launch/context-menu
/// handling is completely unaffected. Also intercepts Escape
/// (`cancelOperation`, standard AppKit convention for the Escape key) so
/// it closes just the folder overlay rather than propagating up to the
/// launcher window's own Escape-hides-the-whole-launcher handling — this
/// view must be made first responder when shown for that interception to
/// actually happen (see the call site).
private final class FolderOverlayBackdropView: NSView {
    var onDismiss: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}

/// Blurs the live grid content behind the folder overlay — matching the
/// Tessera reference's own `.dc.html` mockup
/// (`background:rgba(8,8,9,.55);backdrop-filter:blur(22px)`), which shows
/// the grid as visibly *blurred and darkened*, not just darkened. A purely
/// decorative background must never intercept clicks (same reasoning as
/// `Launcher.NonInteractiveVisualEffectView`, which this file can't import
/// across the module boundary — `Grid` sits below `Launcher` — so this is a
/// local copy of the same one-line fix): overriding `hitTest` to
/// unconditionally return `nil` lets every click fall through to
/// `FolderOverlayBackdropView.mouseDown` (the actual dismiss handler)
/// regardless of this view sitting on top of it in z-order.
private final class NonInteractiveFolderBlurView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
