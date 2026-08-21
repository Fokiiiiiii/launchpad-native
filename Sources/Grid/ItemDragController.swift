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
    /// in the shared glass-surface implementation, even though it wasn't this
    /// bug's cause.
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


    private var pendingItemPress: (indexPath: IndexPath, startPoint: NSPoint)?
    private var activeItemDrag: ItemDrag.ItemDragSession?
    private var itemDragGeneration = 0
    private var lastAnimatedValueByLayer: [ObjectIdentifier: (x: CGFloat, xTime: CFTimeInterval, y: CGFloat, yTime: CFTimeInterval)] = [:]


    func handleItemMouseDown(indexPath: IndexPath, event: NSEvent) {
        guard model.pages.indices.contains(currentPage), model.pages[currentPage].indices.contains(indexPath.item) else { return }
        if let staleSession = activeItemDrag {
            DiagnosticsLog.grid.notice("handleItemMouseDown: new press on item \(indexPath.item, privacy: .public) arrived while item \(staleSession.sourceOriginalIndex, privacy: .public)'s drag was still active — committing the stale session first")
            endItemDrag(session: staleSession)
        }
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
        cell.view.layer?.opacity = 0

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let layer = imageView.layer else { return }
        if !reduceMotion {
            layer.setValue(1.06, forKeyPath: "transform.scale")
            layer.add(GridSpring.animation(keyPath: "transform.scale", from: 1.0, to: 1.06, damping: 0.82, response: 0.20), forKey: "lift")
        }
    }

    private func updateItemDrag(session: ItemDrag.ItemDragSession, point: NSPoint) {
        session.lastPoint = point
        guard let floatingView = session.floatingView, let layer = floatingView.layer else { return }
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
            animateLayerTranslation(layer, toX: targetFrame.minX - originalFrame.minX, toY: targetFrame.minY - originalFrame.minY, damping: 0.90, response: 0.16)
        }
    }

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
