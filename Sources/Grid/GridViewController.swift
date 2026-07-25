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
    private let onLaunch: (ApplicationRecord) -> Void
    private let onBackgroundClick: () -> Void
    private let onRequestUninstall: (String) -> Void

    private let collectionView = GridCollectionView()
    private let scrollView = NSScrollView()
    private let pageControl = PageControlView()
    private let layout = PagedGridLayout()

    private var currentPage = 0
    private var openFolderPopover: NSPopover?
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

        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.onSelectPage = { [weak self] index in self?.jumpToPage(index) }
        pageControl.onPrevious = { [weak self] in self?.jumpToAdjacentPage(delta: -1) }
        pageControl.onNext = { [weak self] in self?.jumpToAdjacentPage(delta: 1) }

        root.addSubview(scrollView)
        root.addSubview(pageControl)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: pageControl.topAnchor, constant: -8),

            pageControl.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            pageControl.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            pageControl.widthAnchor.constraint(equalToConstant: 240),
            pageControl.heightAnchor.constraint(equalToConstant: 32)
        ])

        view = root
        model.onChange = { [weak self] in self?.reload() }
    }

    public func reload() {
        layout.settings = model.gridSettings
        if currentPage >= model.pages.count {
            currentPage = max(model.pages.count - 1, 0)
        }
        collectionView.reloadData()
        pageControl.numberOfPages = model.pages.count
        pageControl.currentPage = currentPage
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
    private func prefetchAdjacentPageIcons() {
        for neighborPage in [currentPage - 1, currentPage + 1] where model.pages.indices.contains(neighborPage) {
            for item in model.pages[neighborPage] {
                guard case .app(let id) = item, let record = model.record(for: id) else { continue }
                let cache = iconCache
                Task {
                    _ = await cache.icon(for: record)
                }
            }
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
        collectionView.selectionIndexPaths = [indexPath]
        collectionView.reloadItems(at: [indexPath])
    }

    /// The data-source-swap approach itself (as opposed to scroll-position
    /// paging) is unchanged and stays that way — see this file's top-level
    /// doc comment for why the earlier scroll-based version never reliably
    /// worked live. This only adds a visual transition *around* the swap: a
    /// quick crossfade, so a page change reads as a transition instead of a
    /// hard cut, without touching the reload logic that's already proven
    /// reliable.
    /// Adds a small directional slide alongside the existing crossfade —
    /// apple-design's "spatial consistency"/"hint in the direction of the
    /// gesture" guidance: a jump to a *later* page slides content out to
    /// the left and the new page in from the right (mirrored for a jump
    /// backward), instead of the fade alone just cutting in place. Still a
    /// discrete jump (not a continuously finger-tracked scroll — that
    /// approach was already tried and abandoned, see this type's top-level
    /// doc comment), so damping stays at 1.0/no bounce per apple-design:
    /// bounce is reserved for motion that actually carried gesture momentum.
    private static let pageSlideOffset: CGFloat = 28

    private func jumpToPage(_ index: Int) {
        guard model.pages.indices.contains(index), index != currentPage || collectionView.numberOfSections == 0 else { return }
        let start = DispatchTime.now()
        pageControl.currentPage = index
        collectionView.wantsLayer = true

        let direction: CGFloat = index >= currentPage ? 1 : -1
        let offset = Self.pageSlideOffset

        if let layer = collectionView.layer {
            layer.setValue(-direction * offset, forKeyPath: "transform.translation.x")
            layer.add(
                Self.springAnimation(keyPath: "transform.translation.x", from: 0, to: -direction * offset, damping: 1.0, response: 0.22),
                forKey: "pageSlideOut"
            )
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            collectionView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Same reasoning as `LauncherWindowController.hide()`:
            // `NSAnimationContext`'s completion handler isn't `@MainActor`-
            // annotated in the SDK, so hop explicitly rather than touching
            // main-actor-isolated view state from a nominally-Sendable
            // closure.
            Task { @MainActor in
                guard let self else { return }
                self.currentPage = index
                self.collectionView.reloadData()
                self.prefetchAdjacentPageIcons()

                // Snap the freshly-reloaded content to the "just off to the
                // correct side" starting position with no animation, then
                // spring it into place — the mirror image of the slide-out.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.collectionView.layer?.setValue(direction * offset, forKeyPath: "transform.translation.x")
                CATransaction.commit()

                if let layer = self.collectionView.layer {
                    layer.setValue(0, forKeyPath: "transform.translation.x")
                    layer.add(
                        Self.springAnimation(keyPath: "transform.translation.x", from: direction * offset, to: 0, damping: 1.0, response: 0.3),
                        forKey: "pageSlideIn"
                    )
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.20
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.collectionView.animator().alphaValue = 1
                }
            }
        })

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
        guard dragDirection == 0, dragNeighborImageView == nil else {
            DiagnosticsLog.grid.notice("beginPageDrag: bailed early (dragDirection=\(self.dragDirection, privacy: .public), neighborAlreadyExists=\(self.dragNeighborImageView != nil, privacy: .public))")
            return
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
        let effective = hasNeighborImage
            ? deltaX
            : (deltaX < 0 ? -Self.rubberBand(-deltaX, dimension: width) : Self.rubberBand(deltaX, dimension: width))

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
    private func endPageDrag(deltaX: CGFloat, velocity: CGFloat) {
        let width = max(collectionView.bounds.width, 1)
        let hasNeighbor = dragNeighborImageView != nil
        let distanceThreshold = width * 0.3
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
        let relativeVelocity = abs(distanceRemaining) > 1 ? velocity / distanceRemaining : 0

        // Distinguish commit vs. abort settle timing. Real captured log
        // evidence from an actual trackpad swipe (user report: "looks like
        // a fade, not a slide") showed a commit resolving from a short flick
        // (e.g. 76pt dragged, ~1000pt/s release velocity) — meaning the
        // spring has to visibly travel nearly the *entire* remaining page
        // width, not the short distance the finger actually covered. The
        // old single damping-1.0/response-0.32 spring (tuned for a quick,
        // small correction) covered that whole distance in well under half
        // a second with no overshoot, which reads as an abrupt snap rather
        // than a continuous slide. A longer response for the commit case
        // specifically, plus a touch of momentum-appropriate bounce
        // (apple-design: add bounce only when the gesture itself carried
        // momentum — a flick/release is exactly that), gives the eye time
        // to actually see the motion. Abort keeps the original fast/no-
        // bounce spring — it only ever travels back the short distance the
        // user dragged, so a quick correction still fits there.
        let (damping, response): (CGFloat, CGFloat) = commit ? (0.86, 0.45) : (1.0, 0.32)

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
        let generation = dragGeneration
        // Clamped defensively — this is a display-timing nicety, not the
        // real safety net (that's the fixed `dragSafetyNetTimeout` fallback
        // armed in `beginPageDrag`, which fires regardless of this value).
        // Raised from 0.6 to 1.0: with the longer commit-case response
        // above, `spring.settlingDuration` can legitimately exceed 0.6s —
        // a too-tight clamp here would schedule `finishPageDrag` (which
        // hard-cancels the layer's in-flight animation and snaps straight
        // to the final position) *before* the spring visually finishes,
        // which would itself look like exactly the abrupt cut this change
        // is trying to fix.
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
        collectionView.reloadData()
        collectionView.layoutSubtreeIfNeeded()
        collectionView.displayIfNeeded()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        collectionView.layer?.removeAllAnimations()
        collectionView.layer?.setValue(0, forKeyPath: "transform.translation.x")
        CATransaction.commit()
        pageControl.currentPage = currentPage
        dragNeighborImageView?.removeFromSuperview()
        dragNeighborImageView = nil
        dragDirection = 0
        dragGeneration += 1
        prefetchAdjacentPageIcons()
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
        dragNeighborImageView?.removeFromSuperview()
        dragNeighborImageView = nil
        dragDirection = 0
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
    /// `log stream`: the pixel-sampling diagnostic in
    /// `logSnapshotContentCheck` read "0/64 sampled points non-transparent"
    /// before this fix — this is what the user's report ("next page's
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
            iconSize: currentIconSize
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
        Self.logSnapshotContentCheck(bitmap, page: page)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    /// Temporary diagnostic (see the user report: "next page's content isn't
    /// visible during the drag" — the neighbor snapshot mechanism itself was
    /// already confirmed via log evidence to run without error/nil, but
    /// that only proves an `NSImage` was produced, not that it has visible
    /// pixels). `cacheDisplay(in:to:)` is documented to work by re-driving
    /// each view's `-drawRect:`-style display path — a hierarchy that's
    /// never been inserted into a real `NSWindow` (as `tempCollectionView`
    /// here never is) is a known way for that to silently produce a blank
    /// or fully-transparent bitmap despite reporting success. Sampling a
    /// handful of points and logging the fraction that are non-transparent
    /// tells us, from a real run via `debugSimulatePageDrag`, whether this
    /// is actually what's happening — without needing Accessibility
    /// permission or the user's own hands-on retest.
    private static func logSnapshotContentCheck(_ bitmap: NSBitmapImageRep, page: Int) {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else {
            DiagnosticsLog.grid.notice("renderPageSnapshot: page \(page, privacy: .public) bitmap has zero size (\(width, privacy: .public)x\(height, privacy: .public))")
            return
        }
        var sampled = 0
        var nonTransparent = 0
        let steps = 8
        for xi in 0..<steps {
            for yi in 0..<steps {
                let x = min(width - 1, xi * width / steps)
                let y = min(height - 1, yi * height / steps)
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                sampled += 1
                if color.alphaComponent > 0.01 { nonTransparent += 1 }
            }
        }
        DiagnosticsLog.grid.notice("renderPageSnapshot: page \(page, privacy: .public) size=\(width, privacy: .public)x\(height, privacy: .public), \(nonTransparent, privacy: .public)/\(sampled, privacy: .public) sampled points non-transparent")
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
        let targetFraction: CGFloat = commit ? 0.5 : 0.05
        let steps = 10
        for step in 1...steps {
            updatePageDrag(deltaX: -width * targetFraction * CGFloat(step) / CGFloat(steps))
        }
        endPageDrag(deltaX: -width * targetFraction, velocity: commit ? -900 : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                DiagnosticsLog.launcher.info("debugSimulatePageDrag: ended at page \(self.currentPage, privacy: .public) (was \(startPage, privacy: .public))")
            }
        }
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

    private func openFolder(_ folderID: FolderID, anchorIndexPath: IndexPath) {
        let start = DispatchTime.now()
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
                guard let self else { return }
                self.model.removeFromFolder(folderID, folderPage: folderPage, folderIndex: folderIndex, toPage: self.currentPage)
                Task { await self.model.save() }
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
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        DiagnosticsLog.launcher.info("folder transition: build+show popover took \(ms, privacy: .public)ms")
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
        case .folder:
            return ContextMenuBuilder.folderMenu(rename: { [weak self] in
                self?.promptRenameFolder(at: indexPath)
            })
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
                addToDock: {
                    DiagnosticsLog.launcher.info("Add to Dock requested for \(record.bundleIdentifier, privacy: .public); drag the icon onto the real Dock to complete this (see GridCollectionView pasteboard writer).")
                },
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

    /// The icon size the grid is *actually* rendering right now — not the
    /// same thing as `model.gridSettings.iconSize`. Cells are scaled to the
    /// cell's own computed size (with `gridSettings.iconSize` only acting as
    /// a ceiling), since a fixed pixel value made icons look tiny inside the
    /// huge cells a sparse grid (e.g. few columns/rows) produces. Exposed so
    /// other surfaces showing the same apps — the search results list — can
    /// match this exactly instead of independently reapplying the raw
    /// setting, which visibly disagreed with what the grid displayed
    /// whenever the proportional size differed from the setting (confirmed:
    /// user's real grid is 6x3 with `iconSize` 160, but the proportional
    /// formula renders larger than that on their screen).
    public var currentIconSize: Double {
        let cellSize = layout.currentCellSize
        let proportionalSize = min(cellSize.width, cellSize.height) * 0.55
        return proportionalSize > 0 ? min(proportionalSize, model.gridSettings.iconSize * 1.5) : model.gridSettings.iconSize
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
        let isSelected = collectionView.selectionIndexPaths.contains(indexPath)
        let iconSize = currentIconSize
        switch model.pages[currentPage][indexPath.item] {
        case .app(let id):
            guard let record = model.record(for: id) else { return cell }
            let cache = iconCache
            let displayName = model.displayName(for: record)
            cell.configureAsApp(record: record, icon: NSImage(), isSelected: isSelected, iconSize: iconSize, displayName: displayName)
            let expectedKey = record.iconCacheKey
            Task { @MainActor in
                let icon = await cache.icon(for: record)
                // The cell may have been recycled for a different record by
                // the time this fetch completes (reloadData() fires on
                // every grid-settings Apply and search keystroke) — only
                // apply if it's still showing what we started fetching for.
                guard cell.currentRequestKey == expectedKey else { return }
                cell.configureAsApp(record: record, icon: icon, isSelected: isSelected, iconSize: iconSize, displayName: displayName)
            }
        case .folder(let folderID):
            let folder = model.folders[folderID]
            let count = folder?.pages.reduce(0) { $0 + $1.count } ?? 0
            cell.configureAsFolder(name: folder?.name ?? L10n.defaultFolderName, itemCount: count, isSelected: isSelected, iconSize: iconSize)
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
        /// The floating view's frame, in root-view coordinates, set exactly
        /// once at creation and never reassigned — see `updateItemDrag`'s
        /// doc comment for why: all *movement* after that happens purely
        /// via `transform.translation.x/y`, matching every other continuous
        /// drag in this codebase (page-drag, reorder preview). Needed here
        /// as the fixed baseline those translation deltas are computed from.
        var floatingViewOriginalFrameInRoot: NSRect = .zero
        /// Offset from the cell's origin to where the user actually grabbed
        /// it — respected while following the cursor so the icon doesn't
        /// jump to be centered under the pointer (apple-design's direct-
        /// manipulation guidance).
        let grabOffset: NSPoint
        var floatingView: NSView?
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
        let generation: Int

        init(sourcePage: Int, sourceOriginalIndex: Int, draggedItem: LayoutItem, originalFrame: NSRect, grabOffset: NSPoint, generation: Int) {
            self.sourcePage = sourcePage
            self.sourceOriginalIndex = sourceOriginalIndex
            self.draggedItem = draggedItem
            self.originalFrame = originalFrame
            self.grabOffset = grabOffset
            self.candidateSlot = sourceOriginalIndex
            self.pendingRawSlot = sourceOriginalIndex
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
    private var itemDragGeneration = 0

    private static let itemDragThresholdDistance: CGFloat = 6
    private static let itemDragEdgeZoneWidth: CGFloat = 70
    private static let itemDragEdgeHoverDelay: TimeInterval = 0.45
    private static let itemDragFolderHoverDelay: TimeInterval = 0.5
    private static let itemDragReorderDebounce: TimeInterval = 0.12
    private static let itemDragFolderZoneInset: CGFloat = 0.2 // ~60% center region

    private func handleItemMouseDown(indexPath: IndexPath, event: NSEvent) {
        guard model.pages.indices.contains(currentPage), model.pages[currentPage].indices.contains(indexPath.item) else { return }
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
        collectionView.selectionIndexPaths = [indexPath]
        for previous in previousSelection where previous != indexPath {
            (collectionView.item(at: previous) as? GridCellItem)?.applySelection(false)
        }
        (collectionView.item(at: indexPath) as? GridCellItem)?.applySelection(true)

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
    private func cancelItemDragIfNeeded() {
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
    private var itemDragGlobalMouseUpMonitor: Any?

    private func armItemDragSafetyNets(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.itemDragSafetyNetTimeout) { [weak self] in
            Task { @MainActor in
                guard let self, let session = self.activeItemDrag, session.generation == generation else { return }
                DiagnosticsLog.grid.notice("armItemDragSafetyNets: fallback timeout fired, force-reverting")
                self.revertItemDrag(session: session)
            }
        }
        guard itemDragGlobalMouseUpMonitor == nil else { return }
        itemDragGlobalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self, let session = self.activeItemDrag else { return }
            DiagnosticsLog.grid.notice("armItemDragSafetyNets: global mouseUp monitor fired while a drag was still active — GridCollectionView never received it, committing via this fallback instead")
            self.endItemDrag(session: session)
        }
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
        let image = snapshotImage(of: cell.view)
        let frameInRoot = collectionView.convert(session.originalFrame, to: view)
        let imageView = NSImageView(frame: frameInRoot)
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.wantsLayer = true
        imageView.layer?.zPosition = 1000
        imageView.layer?.shadowOpacity = 0.35
        imageView.layer?.shadowRadius = 12
        imageView.layer?.shadowOffset = CGSize(width: 0, height: -6)
        view.addSubview(imageView, positioned: .above, relativeTo: nil)
        session.floatingView = imageView
        session.floatingViewOriginalFrameInRoot = frameInRoot
        cell.view.isHidden = true

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
        let targetOriginInCollectionView = NSPoint(x: point.x - session.grabOffset.x, y: point.y - session.grabOffset.y)
        let targetOriginInRoot = collectionView.convert(targetOriginInCollectionView, to: view)
        let dx = targetOriginInRoot.x - session.floatingViewOriginalFrameInRoot.minX
        let dy = targetOriginInRoot.y - session.floatingViewOriginalFrameInRoot.minY

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(dx, forKeyPath: "transform.translation.x")
        layer.setValue(dy, forKeyPath: "transform.translation.y")
        CATransaction.commit()

        evaluateReorderCandidate(session: session, point: point)
        evaluateFolderCandidate(session: session, point: point)
        evaluateEdgeCandidate(session: session, point: point)
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

    /// Nearest-remaining-cell + a short debounce timer — a simplified stand-
    /// in for the spec's precise geometric hysteresis band (7.3), chosen to
    /// avoid over-fitting timing constants that can't be hands-on tuned in
    /// this session (no Accessibility permission for real trackpad/mouse
    /// testing). Achieves the same practical goal: a candidate slot only
    /// commits once the pointer has settled near it, not on every frame of
    /// raw movement.
    private func insertionSlot(forPoint point: NSPoint, excluding sourceOriginalIndex: Int) -> Int? {
        guard model.pages.indices.contains(currentPage) else { return nil }
        let items = model.pages[currentPage]
        var naturalPos = 0
        var closestNaturalPos = 0
        var closestDistance = CGFloat.greatestFiniteMagnitude
        var closestFrame = NSRect.zero
        var found = false
        for originalIndex in items.indices where originalIndex != sourceOriginalIndex {
            defer { naturalPos += 1 }
            guard let frame = layout.layoutAttributesForItem(at: IndexPath(item: originalIndex, section: 0))?.frame else { continue }
            let dx = frame.midX - point.x
            let dy = frame.midY - point.y
            let distance = dx * dx + dy * dy
            if distance < closestDistance {
                closestDistance = distance
                closestNaturalPos = naturalPos
                closestFrame = frame
                found = true
            }
        }
        guard found else { return 0 }
        return point.x > closestFrame.midX ? closestNaturalPos + 1 : closestNaturalPos
    }

    private func evaluateReorderCandidate(session: ItemDragSession, point: NSPoint) {
        guard let rawSlot = insertionSlot(forPoint: point, excluding: session.sourceOriginalIndex),
              rawSlot != session.pendingRawSlot else { return }
        session.pendingRawSlot = rawSlot
        session.reorderTimer?.invalidate()
        session.reorderTimer = Timer.scheduledTimer(withTimeInterval: Self.itemDragReorderDebounce, repeats: false) { [weak self, weak session] _ in
            guard let self, let session, session.generation == self.itemDragGeneration else { return }
            self.commitReorderCandidate(session: session, slot: rawSlot)
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
        for originalIndex in items.indices where originalIndex != session.sourceOriginalIndex {
            let previewSlot = naturalPos < session.candidateSlot ? naturalPos : naturalPos + 1
            naturalPos += 1
            guard let cell = collectionView.item(at: IndexPath(item: originalIndex, section: 0)) as? GridCellItem,
                  let originalFrame = layout.layoutAttributesForItem(at: IndexPath(item: originalIndex, section: 0))?.frame,
                  let layer = cell.view.layer else { continue }
            let targetFrame = frameForSlot(previewSlot)
            animateLayerTranslation(layer, toX: targetFrame.minX - originalFrame.minX, toY: targetFrame.minY - originalFrame.minY)
        }
    }

    private func animateLayerTranslation(_ layer: CALayer, toX dx: CGFloat, toY dy: CGFloat) {
        let presentationLayer = layer.presentation() ?? layer
        let currentX = (presentationLayer.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
        let currentY = (presentationLayer.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
        layer.setValue(dx, forKeyPath: "transform.translation.x")
        layer.setValue(dy, forKeyPath: "transform.translation.y")
        layer.add(Self.springAnimation(keyPath: "transform.translation.x", from: currentX, to: dx, damping: 0.86, response: 0.24), forKey: "reorderX")
        layer.add(Self.springAnimation(keyPath: "transform.translation.y", from: currentY, to: dy, damping: 0.86, response: 0.24), forKey: "reorderY")
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
    /// semantics (unchanged by this rewrite).
    private func evaluateFolderCandidate(session: ItemDragSession, point: NSPoint) {
        guard case .app = session.draggedItem, model.pages.indices.contains(currentPage) else {
            clearFolderCandidate(session: session)
            return
        }
        let items = model.pages[currentPage]
        var target: Int?
        for index in items.indices where index != session.sourceOriginalIndex {
            guard let frame = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { continue }
            let inset = min(frame.width, frame.height) * Self.itemDragFolderZoneInset
            let centerZone = frame.insetBy(dx: inset, dy: inset)
            if centerZone.contains(point) { target = index; break }
        }
        guard target != session.pendingRawFolderCandidateIndex else { return }
        session.pendingRawFolderCandidateIndex = target
        session.folderTimer?.invalidate()
        guard let target else {
            clearFolderCandidate(session: session)
            return
        }
        session.folderTimer = Timer.scheduledTimer(withTimeInterval: Self.itemDragFolderHoverDelay, repeats: false) { [weak self, weak session] _ in
            guard let self, let session, session.generation == self.itemDragGeneration else { return }
            self.commitFolderCandidate(session: session, index: target)
        }
    }

    private func commitFolderCandidate(session: ItemDragSession, index: Int) {
        guard session.folderCandidateOriginalIndex != index else { return }
        clearFolderCandidateHighlight(session: session)
        session.folderCandidateOriginalIndex = index
        DiagnosticsLog.grid.notice("commitFolderCandidate: index \(index, privacy: .public)")
        guard let cell = collectionView.item(at: IndexPath(item: index, section: 0)) as? GridCellItem, let layer = cell.view.layer else { return }
        layer.add(Self.springAnimation(keyPath: "transform.scale", from: 1.0, to: 1.06, damping: 0.82, response: 0.2), forKey: "folderCandidate")
        layer.transform = CATransform3DMakeScale(1.06, 1.06, 1)
    }

    private func clearFolderCandidate(session: ItemDragSession) {
        session.pendingRawFolderCandidateIndex = nil
        session.folderTimer?.invalidate()
        clearFolderCandidateHighlight(session: session)
    }

    private func clearFolderCandidateHighlight(session: ItemDragSession) {
        guard let index = session.folderCandidateOriginalIndex else { return }
        session.folderCandidateOriginalIndex = nil
        guard let cell = collectionView.item(at: IndexPath(item: index, section: 0)) as? GridCellItem else { return }
        resetItemTransform(cell.view)
    }

    // MARK: Page-edge turning while dragging

    /// Spec 9: holding the dragged icon near a page edge previews and then
    /// commits a page turn, while the dragged icon itself stays fixed under
    /// the pointer (it's a floating overlay on `view`, independent of the
    /// collection view being transformed) — only the grid/background/page
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
        session.edgeTimer = Timer.scheduledTimer(withTimeInterval: Self.itemDragEdgeHoverDelay, repeats: false) { [weak self, weak session] _ in
            guard let self, let session, session.generation == self.itemDragGeneration, session.edgeDirection == direction else { return }
            self.commitPageTurnDuringDrag(session: session, direction: direction)
        }
    }

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

        let width = max(collectionView.bounds.width, 1)
        let offset: CGFloat = direction > 0 ? -width : width
        collectionView.wantsLayer = true
        collectionView.layer?.add(Self.springAnimation(keyPath: "transform.translation.x", from: 0, to: offset, damping: 1.0, response: 0.28), forKey: "itemDragPageTurnOut")
        collectionView.layer?.setValue(offset, forKeyPath: "transform.translation.x")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            Task { @MainActor in
                guard let self, self.activeItemDrag === session, session.generation == self.itemDragGeneration else { return }
                self.currentPage = targetPage
                self.collectionView.reloadData()
                self.collectionView.layoutSubtreeIfNeeded()

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.collectionView.layer?.setValue(0, forKeyPath: "transform.translation.x")
                CATransaction.commit()
                self.pageControl.currentPage = targetPage
                self.prefetchAdjacentPageIcons()

                session.pendingRawSlot = -1
                session.candidateSlot = self.model.pages.indices.contains(targetPage) ? self.model.pages[targetPage].count : 0
                session.edgeDirection = 0
                self.updateItemDrag(session: session, point: session.lastPoint)
            }
        }
    }

    // MARK: Drop / settle / cancel

    private func endItemDrag(session: ItemDragSession) {
        session.invalidateTimers()
        activeItemDrag = nil

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
        let targetFrameInRoot = collectionView.convert(targetFrame, to: view)
        let dx = targetFrameInRoot.minX - session.floatingViewOriginalFrameInRoot.minX
        let dy = targetFrameInRoot.minY - session.floatingViewOriginalFrameInRoot.minY

        animateLayerTranslation(layer, toX: dx, toY: dy)
        layer.setValue(1.0, forKeyPath: "transform.scale")
        layer.add(Self.springAnimation(keyPath: "transform.scale", from: 1.06, to: 1.0, damping: 1.0, response: 0.18), forKey: "settleScale")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            Task { @MainActor in
                floatingView.removeFromSuperview()
                self?.collectionView.item(at: IndexPath(item: targetOriginalIndex, section: 0))?.view.isHidden = false
                self?.collectionView.reloadData()
            }
        }
    }

    /// Spec 13.2/13.3: invalid drop or cancel — spring back to the original
    /// cell (same transform-only approach as `settleFloatingView`), undo
    /// any reorder preview, no model mutation.
    private func revertItemDrag(session: ItemDragSession) {
        session.invalidateTimers()
        activeItemDrag = nil
        // See endItemDrag's doc comment: reset before stopWobble(), not
        // after, so the reset's own transform write still has an active
        // animation on these layers to piggyback its repaint on.
        clearFolderCandidateHighlight(session: session)
        for item in collectionView.visibleItems() { resetItemTransform(item.view) }
        stopWobble()

        guard let floatingView = session.floatingView, let layer = floatingView.layer else { return }
        animateLayerTranslation(layer, toX: 0, toY: 0)
        layer.setValue(1.0, forKeyPath: "transform.scale")
        layer.add(Self.springAnimation(keyPath: "transform.scale", from: 1.06, to: 1.0, damping: 1.0, response: 0.2), forKey: "revertScale")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            Task { @MainActor in
                floatingView.removeFromSuperview()
            }
        }
        collectionView.item(at: IndexPath(item: session.sourceOriginalIndex, section: 0))?.view.isHidden = false
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

    init(items: [LayoutItem], model: GridModel, iconCache: IconCache, itemIdentifier: NSUserInterfaceItemIdentifier, iconSize: Double) {
        self.items = items
        self.model = model
        self.iconCache = iconCache
        self.itemIdentifier = itemIdentifier
        self.iconSize = iconSize
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
            cell.configureAsApp(record: record, icon: icon, isSelected: false, iconSize: iconSize, displayName: displayName)
        case .folder(let folderID):
            let folder = model.folders[folderID]
            let count = folder?.pages.reduce(0) { $0 + $1.count } ?? 0
            cell.configureAsFolder(name: folder?.name ?? L10n.defaultFolderName, itemCount: count, isSelected: false, iconSize: iconSize)
        }
        return cell
    }
}
