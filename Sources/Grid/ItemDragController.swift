import AppKit
import Catalog
import Diagnostics
import Persistence

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

/// The grid's item-drag state machine: press feedback, lift, live reorder
/// preview, folder creation, drag-to-the-edge page turning, and every exit
/// path back out of a drag.
///
/// Split out of `GridViewController` because it is by far the largest single
/// responsibility in that file and the one with the most history — nearly
/// every ordering detail in here exists because a specific way of getting it
/// wrong was reproduced on real hardware, and the doc comments record which.
/// **Nothing in the moved code changed**: the same statements run in the same
/// order, against the same views. What changed is only how this reaches the
/// few things it does not own — the current page, committing a page change,
/// icon prefetching, page snapshots, launching an app, and the keyboard
/// selection ring — which now arrive as explicit callbacks instead of being
/// reachable as private members of the same class.
///
/// The grid's views are held directly (same property names as before) rather
/// than routed through callbacks: the drag reads `collectionView` in about
/// fifty places and `view` in a dozen, and forcing those through an indirection
/// would have meant editing the very lines whose exact form is what several of
/// these fixes consist of.
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

@MainActor
final class ItemDragController {
    /// The parts of the grid this does not own.
    ///
    /// `currentPage` is read-only here on purpose. A drag can carry the pointer
    /// across page turns, but *committing* one touches layout, the page control
    /// and prefetching in an order that a real flash bug was fixed by getting
    /// right — so that whole sequence stays in the controller, behind
    /// `commitPageChange`.
    struct Callbacks {
        let currentPage: () -> Int
        let commitPageChange: (Int) -> Void
        let prefetchIcons: (Int) -> Void
        let pageSnapshot: (Int, NSSize) -> NSImage?
        let activateItem: (IndexPath) -> Void
        let clearKeyboardSelection: () -> Void
    }

    private let model: GridModel
    private let layout: PagedGridLayout
    private let callbacks: Callbacks
    /// Unowned because the controller owns both this object and these views;
    /// they cannot outlive it.
    private unowned let collectionView: GridCollectionView
    private unowned let scrollView: NSScrollView
    private unowned let view: NSView

    private var currentPage: Int { callbacks.currentPage() }

    init(
        model: GridModel,
        layout: PagedGridLayout,
        collectionView: GridCollectionView,
        scrollView: NSScrollView,
        view: NSView,
        callbacks: Callbacks
    ) {
        self.model = model
        self.layout = layout
        self.collectionView = collectionView
        self.scrollView = scrollView
        self.view = view
        self.callbacks = callbacks
    }

    deinit {
        itemDragGlobalMouseUpMonitor?.remove()
    }

    /// Whether a drag is in flight — read by the debug hooks, which drive the
    /// real handlers below with synthetic events and then check that the state
    /// machine actually returned to rest.
    var isDragging: Bool { activeItemDrag != nil }

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

    private var pendingItemPress: (indexPath: IndexPath, startPoint: NSPoint)?
    private var activeItemDrag: ItemDrag.ItemDragSession?
    private var itemDragGeneration = 0
    /// Round 12 §8c: lightweight velocity approximation for
    /// `animateLayerTranslation`'s re-targeted springs (reorder-preview
    /// shift, item-drag page-turn) — keyed by layer identity so a cell
    /// reused for a *different* record on a later drag never inherits a
    /// stale velocity estimate. Cleared in `endItemDrag`/`revertItemDrag`.
    private var lastAnimatedValueByLayer: [ObjectIdentifier: (x: CGFloat, xTime: CFTimeInterval, y: CGFloat, yTime: CFTimeInterval)] = [:]


    func handleItemMouseDown(indexPath: IndexPath, event: NSEvent) {
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
        callbacks.clearKeyboardSelection()
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

    func handleItemMouseDragged(event: NSEvent) {
        let point = collectionView.convert(event.locationInWindow, from: nil)
        if let session = activeItemDrag {
            updateItemDrag(session: session, point: point)
            return
        }
        guard let pending = pendingItemPress else { return }
        let distance = hypot(point.x - pending.startPoint.x, point.y - pending.startPoint.y)
        guard distance >= ItemDrag.itemDragThresholdDistance else { return }
        beginItemDrag(indexPath: pending.indexPath, pressPoint: pending.startPoint, currentPoint: point)
    }

    func handleItemMouseUp(event: NSEvent) {
        if let session = activeItemDrag {
            endItemDrag(session: session)
            return
        }
        guard let pending = pendingItemPress else { return }
        pendingItemPress = nil
        applyPressFeedback(at: pending.indexPath, pressed: false)
        callbacks.activateItem(pending.indexPath)
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
    func cancelItemDragIfNeeded() {
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
        let session = ItemDrag.ItemDragSession(
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
        DispatchQueue.main.asyncAfter(deadline: .now() + ItemDrag.itemDragSafetyNetTimeout) { [weak self] in
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

    private func createFloatingDragView(session: ItemDrag.ItemDragSession) {
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
            layer.add(GridSpring.animation(keyPath: "transform.scale", from: 1.0, to: 1.06, damping: 0.82, response: 0.20), forKey: "lift")
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
    private func updateItemDrag(session: ItemDrag.ItemDragSession, point: NSPoint) {
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
        // gating this early, before the folder hover delay fires, is what
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
        GridSlotGeometry.frameForSlot(
            slot,
            columns: model.gridSettings.columns,
            cellSize: layout.currentCellSize,
            horizontalSpacing: CGFloat(model.gridSettings.horizontalSpacing),
            verticalSpacing: CGFloat(model.gridSettings.verticalSpacing),
            margin: CGFloat(model.gridSettings.pageMargins)
        )
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
        return GridSlotGeometry.insertionSlot(
            forPoint: point,
            columns: model.gridSettings.columns,
            cellSize: layout.currentCellSize,
            horizontalSpacing: CGFloat(model.gridSettings.horizontalSpacing),
            verticalSpacing: CGFloat(model.gridSettings.verticalSpacing),
            margin: CGFloat(model.gridSettings.pageMargins),
            occupiedSlots: excludedIndex == nil ? pageCount : max(pageCount - 1, 0)
        )
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
    private func evaluateReorderCandidate(session: ItemDrag.ItemDragSession, point: NSPoint) {
        guard let rawSlot = insertionSlot(forPoint: point, excluding: session.sourceIndexOnCurrentPage) else { return }
        guard rawSlot != session.candidateSlot else {
            session.reorderTimer?.invalidate()
            return
        }
        guard GridSlotGeometry.exceedsHysteresis(
            point: point,
            committedFrame: frameForSlot(session.candidateSlot),
            fraction: ItemDrag.itemDragHysteresisFraction
        ) else {
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
        session.reorderTimer = Timer.scheduledTimer(withTimeInterval: ItemDrag.itemDragReorderDebounce, repeats: false) { [weak self, weak session] _ in
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

    private func commitReorderCandidate(session: ItemDrag.ItemDragSession, slot: Int) {
        guard slot != session.candidateSlot else { return }
        session.candidateSlot = slot
        animateReorderPreview(session: session)
    }

    /// Spec 8.2: remaining items spring to their preview slot — no fade, no
    /// rotation, uniform timing regardless of row. Only the *visual*
    /// arrangement changes here (via each live cell view's own layer
    /// transform); `model.pages` itself is untouched until the drop
    /// actually commits in `endItemDrag`.
    private func animateReorderPreview(session: ItemDrag.ItemDragSession) {
        guard model.pages.indices.contains(currentPage) else { return }
        let items = model.pages[currentPage]
        var naturalPos = 0
        for originalIndex in items.indices where originalIndex != session.sourceIndexOnCurrentPage {
            let previewSlot = GridSlotGeometry.previewSlot(naturalPosition: naturalPos, candidateSlot: session.candidateSlot)
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
        let velocityX = GridSpring.estimateVelocity(from: previous?.x, at: previous?.xTime, to: currentX, at: now)
        let velocityY = GridSpring.estimateVelocity(from: previous?.y, at: previous?.yTime, to: currentY, at: now)
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
        layer.add(GridSpring.animation(keyPath: "transform.translation.x", from: currentX, to: dx, damping: damping, response: response, initialVelocity: relativeVX), forKey: "reorderX")
        layer.add(GridSpring.animation(keyPath: "transform.translation.y", from: currentY, to: dy, damping: damping, response: response, initialVelocity: relativeVY), forKey: "reorderY")
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
    private func folderZoneTarget(session: ItemDrag.ItemDragSession, point: NSPoint) -> Int? {
        guard case .app = session.draggedItem, model.pages.indices.contains(currentPage) else { return nil }
        let items = model.pages[currentPage]
        for index in items.indices where index != session.sourceIndexOnCurrentPage {
            guard let frame = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { continue }
            let centerZone = GridSlotGeometry.folderZone(in: frame, inset: ItemDrag.itemDragFolderZoneInset)
            if centerZone.contains(point) { return index }
        }
        return nil
    }

    private func evaluateFolderCandidate(session: ItemDrag.ItemDragSession, point: NSPoint, zoneTarget: Int?) {
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
        // `commitFolderCandidate` fires after the hover delay.
        showFolderZoneIndicator(session: session, targetIndex: zoneTarget)
        beginFloatingViewFolderPull(session: session, engaged: true)
        session.folderTimer = Timer.scheduledTimer(withTimeInterval: ItemDrag.itemDragFolderHoverDelay, repeats: false) { [weak self, weak session] _ in
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

    private func commitFolderCandidate(session: ItemDrag.ItemDragSession, index: Int) {
        guard session.folderCandidateOriginalIndex != index else { return }
        clearFolderCandidateHighlight(session: session)
        session.folderCandidateOriginalIndex = index
        // The ring's job (showing "not yet committed, hover to confirm")
        // is done — the target's own 1.06x growth below takes over as the
        // "committed" signal.
        clearFolderZoneIndicator(session: session)
        DiagnosticsLog.grid.notice("commitFolderCandidate: index \(index, privacy: .public)")
        guard let cell = collectionView.item(at: IndexPath(item: index, section: 0)) as? GridCellItem, let layer = cell.view.layer else { return }
        layer.add(GridSpring.animation(keyPath: "transform.scale", from: 1.0, to: 1.06, damping: 0.82, response: 0.2), forKey: "folderCandidate")
        // Keypath assignment, not a raw `layer.transform = ...` assignment
        // — this file's consistent convention (see `updateItemDrag`'s doc
        // comment) is translation via `transform.translation.x/y` and
        // scale via `transform.scale`, never a bare `.transform` overwrite,
        // so scale changes here compose cleanly with any translation this
        // same layer might carry.
        layer.setValue(1.06, forKeyPath: "transform.scale")
    }

    private func clearFolderCandidate(session: ItemDrag.ItemDragSession) {
        session.pendingRawFolderCandidateIndex = nil
        session.folderTimer?.invalidate()
        clearFolderCandidateHighlight(session: session)
        clearFolderZoneIndicator(session: session)
        beginFloatingViewFolderPull(session: session, engaged: false)
    }

    /// Real, confirmed report ("グループ化しようとするとアプリが逃げる"):
    /// called from `updateItemDrag` whenever the pointer is inside another
    /// app's folder drop zone, *before* the hover delay confirms a
    /// folder candidate — pins the reorder preview back to its identity
    /// state (every item at its own natural slot, zero visual
    /// displacement) so the target app being hovered over never gets
    /// nudged aside by a reorder candidate change while the user is trying
    /// to hold the pointer over it.
    private func suppressReorderForFolderZone(session: ItemDrag.ItemDragSession) {
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

    private func clearFolderCandidateHighlight(session: ItemDrag.ItemDragSession) {
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
    private func beginFloatingViewFolderPull(session: ItemDrag.ItemDragSession, engaged: Bool) {
        guard let layer = session.floatingView?.layer else { return }
        let liftScale: CGFloat = 1.06
        let pullScale: CGFloat = 0.92
        let targetScale = engaged ? pullScale : liftScale
        let currentScale = (layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? (engaged ? liftScale : pullScale)
        guard abs(currentScale - targetScale) > 0.001 else { return }
        layer.setValue(targetScale, forKeyPath: "transform.scale")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        layer.add(GridSpring.animation(keyPath: "transform.scale", from: currentScale, to: targetScale, damping: 0.82, response: 0.2), forKey: "folderPull")
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
    private func showFolderZoneIndicator(session: ItemDrag.ItemDragSession, targetIndex: Int) {
        clearFolderZoneIndicator(session: session, animated: false)
        guard let cell = collectionView.item(at: IndexPath(item: targetIndex, section: 0)) as? GridCellItem else { return }
        let host = session.floatingViewHost ?? view
        host.wantsLayer = true
        host.clipsToBounds = false
        host.layer?.masksToBounds = false
        let iconFrameInHost = cell.view.convert(cell.iconFrame, to: host)
        guard iconFrameInHost.width > 0, iconFrameInHost.height > 0 else { return }

        let indicatorSize = iconFrameInHost.width * ItemDrag.itemDragFolderZoneIndicatorScale
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
        let cornerRadius = indicatorSize * ItemDrag.itemDragFolderZoneIndicatorCornerRatio
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
        indicator.layer?.add(GridSpring.animation(keyPath: "opacity", from: 0, to: 1, damping: 1.0, response: 0.12), forKey: "zoneFadeIn")

        guard !reduceMotion else { return }
        let sweep = CABasicAnimation(keyPath: "strokeEnd")
        sweep.fromValue = 0
        sweep.toValue = 1
        sweep.duration = ItemDrag.itemDragFolderHoverDelay
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.isRemovedOnCompletion = false
        sweep.fillMode = .forwards
        progressRing.strokeEnd = 1
        progressRing.add(sweep, forKey: "folderHoverProgress")
    }

    private func clearFolderZoneIndicator(session: ItemDrag.ItemDragSession, animated: Bool = true) {
        guard let indicator = session.folderZoneIndicatorView else { return }
        session.folderZoneIndicatorView = nil
        guard animated else {
            indicator.removeFromSuperview()
            return
        }
        let currentOpacity = indicator.layer?.presentation()?.opacity ?? 1
        CATransaction.begin()
        CATransaction.setCompletionBlock { indicator.removeFromSuperview() }
        indicator.layer?.add(GridSpring.animation(keyPath: "opacity", from: CGFloat(currentOpacity), to: 0, damping: 1.0, response: 0.1), forKey: "zoneFadeOut")
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
    private func evaluateEdgeCandidate(session: ItemDrag.ItemDragSession, point: NSPoint) {
        let width = max(collectionView.bounds.width, 1)
        var direction = 0
        if point.x < ItemDrag.itemDragEdgeZoneWidth, currentPage > 0 {
            direction = -1
        } else if point.x > width - ItemDrag.itemDragEdgeZoneWidth, currentPage < model.pages.count - 1 {
            direction = 1
        }

        guard direction != session.edgeDirection else { return }
        session.edgeDirection = direction
        session.edgeTimer?.invalidate()
        guard direction != 0 else { return }
        let committedDirection = direction
        session.edgeTimer = Timer.scheduledTimer(withTimeInterval: ItemDrag.itemDragEdgeHoverDelay, repeats: false) { [weak self, weak session] _ in
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
    private func updateEdgePeek(session: ItemDrag.ItemDragSession, point: NSPoint) {
        let width = max(collectionView.bounds.width, 1)
        let zone = ItemDrag.itemDragEdgeZoneWidth
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
            callbacks.prefetchIcons(currentPage + direction)
            guard let image = callbacks.pageSnapshot(currentPage + direction, collectionView.bounds.size) else { return }
            let imageView = PageSnapshotRenderer.makeNeighborImageView(
                image: image,
                direction: direction,
                pageWidth: width,
                scrollViewFrame: scrollView.frame
            )
            view.addSubview(imageView, positioned: .above, relativeTo: scrollView)
            session.edgePeekImageView = imageView
        }

        // Real, confirmed report ("ページ端についてその先へ無理や進もう
        // とした時に起きるアニメーションが過剰すぎる"): reuses the same
        // rubber-band resistance formula the trackpad page-swipe already
        // uses at its own edges — overshoot-proportional resistance
        // instead of the old linear `proximity * 30` ramp that kept
        // growing the harder the pointer pushed.
        let dampedOffset = GridSpring.rubberBand(penetration, dimension: ItemDrag.itemDragEdgePeekResistanceDimension)
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
    private func clearEdgePeek(session: ItemDrag.ItemDragSession) {
        guard let peekImageView = session.edgePeekImageView else { return }
        let lastOffset = session.lastPeekOffset ?? 0
        collectionView.layer?.add(GridSpring.animation(keyPath: "transform.translation.x", from: lastOffset, to: 0, damping: 0.98, response: 0.20), forKey: "edgePeekRevert")
        collectionView.layer?.setValue(0, forKeyPath: "transform.translation.x")
        peekImageView.removeFromSuperview()
        session.edgePeekImageView = nil
        session.lastPeekOffset = nil
        session.lastPeekTime = nil
    }


    /// (the page-turn commit path in `commitPageTurnDuringDrag` handles its

    private func commitPageTurnDuringDrag(session: ItemDrag.ItemDragSession, direction: Int) {
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
        let rawVelocity = GridSpring.estimateVelocity(from: session.lastPeekOffset, at: session.lastPeekTime, to: presentationX, at: CACurrentMediaTime())
        let boundedVelocity = min(max(rawVelocity, -1600), 1600)
        let relativeVelocity = abs(offset - presentationX) > 1 ? boundedVelocity / (offset - presentationX) : 0
        let peekImageView = session.edgePeekImageView
        session.edgePeekImageView = nil // this function now owns the transition, not clearEdgePeek
        session.lastPeekOffset = nil
        session.lastPeekTime = nil

        collectionView.wantsLayer = true
        let spring = GridSpring.animation(keyPath: "transform.translation.x", from: presentationX, to: offset, damping: 0.98, response: 0.30, initialVelocity: relativeVelocity)
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
            let peekSpring = GridSpring.animation(keyPath: "transform.translation.x", from: peekCurrentX, to: peekTarget, damping: 0.98, response: 0.30, initialVelocity: relativeVelocity)
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
                self.callbacks.commitPageChange(targetPage)

                session.pendingRawSlot = -1
                session.candidateSlot = self.model.pages.indices.contains(targetPage) ? self.model.pages[targetPage].count : 0
                session.edgeDirection = 0
                // Which slot — if any — the dragged item occupies on the page
                // now in view. On any other page it occupies none, so nothing
                // there should be excluded from the reorder preview or from
                // folder targeting. Returning to its *origin* page has to
                // restore the exclusion: a user-reported bug ("次のページまで
                // 持っていって戻すと元の位置に同じアプリが出てきて増殖する")
                // came from clearing this unconditionally — back on the origin
                // page the item was no longer excluded, so its own cell was
                // laid out and drawn again underneath the floating icon the
                // user was still holding, reading as a duplicate.
                session.sourceIndexOnCurrentPage = ItemDrag.sourceIndex(
                    onPage: targetPage,
                    sourcePage: session.sourcePage,
                    sourceOriginalIndex: session.sourceOriginalIndex
                )
                // `reloadData` above rebuilds every cell, and `prepareForReuse`
                // resets the layer opacity `beginItemDrag` used to hide the
                // dragged item's own cell. Back on the origin page that cell
                // exists again and would draw at full opacity underneath the
                // floating icon, so re-apply the same hiding here. Layer
                // opacity, never `isHidden` — see `beginItemDrag` for the
                // event-delivery regression that caused.
                if let indexOnCurrentPage = session.sourceIndexOnCurrentPage {
                    self.collectionView
                        .item(at: IndexPath(item: indexOnCurrentPage, section: 0))?
                        .view.layer?.opacity = 0
                }
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

    private func endItemDrag(session: ItemDrag.ItemDragSession) {
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
    private func settleFloatingView(session: ItemDrag.ItemDragSession) {
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
        layer.add(GridSpring.animation(keyPath: "transform.scale", from: currentScale, to: 1.0, damping: 1.0, response: 0.18), forKey: "settleScale")

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
    private func revertItemDrag(session: ItemDrag.ItemDragSession) {
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
        layer.add(GridSpring.animation(keyPath: "transform.scale", from: currentScale, to: 1.0, damping: 1.0, response: 0.2), forKey: "revertScale")

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
