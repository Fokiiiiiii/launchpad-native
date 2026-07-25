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
    private static let internalDragType = NSPasteboard.PasteboardType("com.launchpadnative.griditem")
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

        layout.settings = model.gridSettings
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(GridCellItem.self, forItemWithIdentifier: itemIdentifier)
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.setDraggingSourceOperationMask(.every, forLocal: false)
        collectionView.registerForDraggedTypes([Self.internalDragType])
        collectionView.menuProvider = { [weak self] indexPath in self?.contextMenu(for: indexPath) }
        collectionView.onSwipePage = { [weak self] delta in self?.jumpToAdjacentPage(delta: delta) }
        collectionView.onSwipeBegan = { [weak self] in self?.beginPageDrag() }
        collectionView.onSwipeChanged = { [weak self] delta in self?.updatePageDrag(deltaX: delta) }
        collectionView.onSwipeEnded = { [weak self] delta, velocity in self?.endPageDrag(deltaX: delta, velocity: velocity) }
        collectionView.onBackgroundClick = { [weak self] in
            // Extra safety-net opportunity for the page-drag machinery (see
            // `resetDragStateIfNeeded`'s doc comment) — harmless no-op if
            // no drag is active.
            self?.resetDragStateIfNeeded()
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
    //  3. A hard, fixed-duration (1s) fallback timer — independent of
    //     `CASpringAnimation.settlingDuration`, which is what silently
    //     misbehaved before — force-resets everything no matter what.
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
        guard dragDirection == 0, dragNeighborImageView == nil else { return }
        guard collectionView.bounds.width > 0 else { return }
        collectionView.wantsLayer = true
        dragHasPrev = currentPage > 0
        dragHasNext = currentPage < model.pages.count - 1
        dragGeneration += 1
        let generation = dragGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
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
            if hasNeighbor, dragNeighborImageView == nil,
               let image = renderPageSnapshot(forPage: currentPage + dragDirection, size: collectionView.bounds.size) {
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
    /// 1s fallback is the real safety net if that duration ever misbehaves.
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

        let targetTranslation: CGFloat = commit ? (dragDirection > 0 ? -width : width) : 0
        let distanceRemaining = targetTranslation - deltaX
        let relativeVelocity = abs(distanceRemaining) > 1 ? velocity / distanceRemaining : 0

        let spring = Self.springAnimation(
            keyPath: "transform.translation.x",
            from: deltaX,
            to: targetTranslation,
            damping: 1.0,
            response: 0.32,
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
        // real safety net (that's the fixed 1s fallback armed in
        // `beginPageDrag`, which fires regardless of this value).
        let settleDuration = min(max(spring.settlingDuration, 0), 0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDuration) { [weak self] in
            Task { @MainActor in
                guard let self, self.dragGeneration == generation else { return }
                self.finishPageDrag(targetPage: targetPage)
            }
        }
    }

    private func finishPageDrag(targetPage: Int) {
        currentPage = targetPage
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        collectionView.layer?.removeAllAnimations()
        collectionView.layer?.setValue(0, forKeyPath: "transform.translation.x")
        CATransaction.commit()
        collectionView.reloadData()
        pageControl.currentPage = currentPage
        dragNeighborImageView?.removeFromSuperview()
        dragNeighborImageView = nil
        dragDirection = 0
        dragGeneration += 1
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
        tempCollectionView.layoutSubtreeIfNeeded()

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
                openNewInstance: record.canOpenNewInstance ? { AppLauncher.launch(record, createsNewInstance: true) } : nil,
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

    /// Set the instant a native drag session actually begins (see the
    /// jiggle-mode delegate methods below) so a pending launch can check it
    /// before firing — see `didSelectItemsAt`'s doc comment for why this is
    /// necessary at all.
    private var dragSessionStartedDuringCurrentGesture = false

    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        // Single click launches/opens — matches real Launchpad convention.
        // BUT: NSCollectionView fires selection (and this delegate method)
        // synchronously on mouseDown, *before* it's known whether the
        // gesture continues into a drag — so launching here unconditionally
        // fired on every attempt to drag-reorder an icon or drag one icon
        // onto another to create a folder, before the drag was ever
        // recognized (confirmed via real user report: dragging opened the
        // app instead of moving it, and folder creation — already
        // implemented and unit-tested in `createOrJoinFolder` below — was
        // effectively unusable over real mouse input for exactly this
        // reason). Deferring the launch decision to the next run-loop tick
        // (not a fixed timer) works because `collectionView(_:draggingSession:
        // willBeginAt:forItemsAt:)` fires synchronously within this same
        // mouseDown-tracking call if a drag *does* get recognized — by the
        // time this `async` block runs (after that whole tracking loop has
        // returned), `dragSessionStartedDuringCurrentGesture` already
        // reflects whether this gesture turned into a drag.
        guard let indexPath = indexPaths.first else { return }
        dragSessionStartedDuringCurrentGesture = false
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.dragSessionStartedDuringCurrentGesture else { return }
            self.activate(at: indexPath)
        }
    }

    // MARK: Drag and drop (within the current page only — see type doc comment)
    //
    // Including `.fileURL` on the pasteboard item for `.app` cells is what
    // makes "drag onto the real Dock" (2.9) work for free: NSCollectionView's
    // built-in drag session already lets the OS hand this off to the Dock
    // process or Finder, no custom NSDraggingSource subclass required.

    public func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>) -> Bool {
        true
    }

    public func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard model.pages.indices.contains(currentPage),
              model.pages[currentPage].indices.contains(indexPath.item) else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString("\(indexPath.item)", forType: Self.internalDragType)
        if case .app(let id) = model.pages[currentPage][indexPath.item], let record = model.record(for: id) {
            pbItem.setString(record.bundleURL.absoluteString, forType: .fileURL)
        }
        return pbItem
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard draggingInfo.draggingPasteboard.string(forType: Self.internalDragType) != nil else { return [] }
        return .move
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let sourceIndexString = draggingInfo.draggingPasteboard.string(forType: Self.internalDragType),
              let sourceIndex = Int(sourceIndexString) else { return false }

        if dropOperation == .on {
            model.createOrJoinFolder(
                sourcePage: currentPage,
                sourceIndex: sourceIndex,
                destinationPage: currentPage,
                destinationIndex: indexPath.item
            )
        } else {
            model.moveItem(
                fromPage: currentPage,
                fromIndex: sourceIndex,
                toPage: currentPage,
                toIndex: indexPath.item
            )
        }
        Task { await model.save() }
        return true
    }

    // MARK: Jiggle mode
    //
    // Real Launchpad/iOS home-screen convention: starting to drag any icon
    // makes every icon on screen wobble, signaling "you're rearranging now."
    // Scoped to just the duration of one native drag session (starts when
    // AppKit's own drag machinery actually begins, stops when it ends,
    // dropped or cancelled) — this project has no "done editing" affordance
    // (no delete badges, no explicit exit button) for a persistent post-drag
    // edit mode the way real Launchpad has, so extending the wobble beyond
    // one drag's lifetime wouldn't have anything meaningful to attach to.

    public func collectionView(
        _ collectionView: NSCollectionView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItemsAt indexPaths: Set<IndexPath>
    ) {
        dragSessionStartedDuringCurrentGesture = true
        startWobble()
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        dragOperation operation: NSDragOperation
    ) {
        // Fires on both a completed drop and a cancelled drag, so this one
        // method covers both — no separate cancel handler needed.
        stopWobble()
    }

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
