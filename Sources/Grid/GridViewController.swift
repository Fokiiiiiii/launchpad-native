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

    private var dragOverlayContainer: NSView?
    private var dragHasPrev = false
    private var dragHasNext = false
    /// Keeps each temporary snapshot render's data source alive for the
    /// duration of the drag — `NSCollectionView.dataSource` doesn't retain
    /// its own reference.
    private var activeSnapshotDataSources: [SnapshotDataSource] = []

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
        collectionView.onBackgroundClick = { [weak self] in self?.onBackgroundClick() }

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

    // MARK: Drag-tracked page paging (real-time finger-following swipe)
    //
    // Deliberately NOT built on NSScrollView's own scroll position — an
    // earlier "one continuous strip, scroll to the page's x-offset"
    // approach was tried and abandoned (see this type's top-level doc
    // comment) after hands-on testing found the page never visibly changed
    // despite the scroll code executing correctly, a real reproducible
    // AppKit quirk. This instead renders static snapshots of the current
    // and adjacent pages and slides them via a direct CALayer transform —
    // the same technique this round's wobble and page-jump-slide animations
    // already use successfully, and it never touches NSScrollView's scroll
    // state at all.
    //
    // Disclosed limitation: this session has no Accessibility/GUI-scripting
    // permission, so none of this can be interactively verified here (no
    // way to simulate a real trackpad gesture) — verified only via
    // build/test/log evidence. Given the prior failure in this exact area,
    // treat this as needing the user's own hands-on confirmation more than
    // usual.

    /// Fires once per gesture, the moment a horizontal swipe is confirmed.
    /// Renders up to three static snapshots (previous/current/next page,
    /// skipping ends that don't exist) and overlays them in front of the
    /// live `collectionView`, which is hidden for the duration of the drag.
    private func beginPageDrag() {
        guard dragOverlayContainer == nil else { return }
        let bounds = collectionView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        dragHasPrev = currentPage > 0
        dragHasNext = currentPage < model.pages.count - 1

        let container = NSView(frame: NSRect(origin: .zero, size: bounds.size))
        container.wantsLayer = true

        func addSnapshot(ofPage page: Int, atXOffset xOffset: CGFloat) {
            guard let image = renderPageSnapshot(forPage: page, size: bounds.size) else { return }
            let imageView = NSImageView(frame: NSRect(x: xOffset, y: 0, width: bounds.width, height: bounds.height))
            imageView.image = image
            imageView.imageScaling = .scaleNone
            container.addSubview(imageView)
        }

        addSnapshot(ofPage: currentPage, atXOffset: 0)
        if dragHasPrev { addSnapshot(ofPage: currentPage - 1, atXOffset: -bounds.width) }
        if dragHasNext { addSnapshot(ofPage: currentPage + 1, atXOffset: bounds.width) }

        view.addSubview(container, positioned: .above, relativeTo: scrollView)
        container.frame = scrollView.frame
        dragOverlayContainer = container
        collectionView.isHidden = true
    }

    /// Called continuously while the gesture is in progress — `deltaX` is
    /// the *cumulative* horizontal delta since the gesture began, applied
    /// 1:1 to the overlay's transform so it tracks the fingers exactly.
    /// Rubber-bands (apple-design's resistance formula) instead of moving
    /// freely past either end when there's no adjacent page to reveal.
    private func updatePageDrag(deltaX: CGFloat) {
        guard let container = dragOverlayContainer else { return }
        let width = max(container.bounds.width, 1)
        var effective = deltaX
        if deltaX < 0 && !dragHasNext {
            effective = -Self.rubberBand(-deltaX, dimension: width)
        } else if deltaX > 0 && !dragHasPrev {
            effective = Self.rubberBand(deltaX, dimension: width)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.layer?.setValue(effective, forKeyPath: "transform.translation.x")
        CATransaction.commit()
    }

    /// Decides the destination page from the final position and estimated
    /// release velocity (a sufficiently fast flick commits even short of
    /// the distance threshold — apple-design's momentum projection), then
    /// springs the overlay the rest of the way with the release velocity
    /// handed off (not hard-cut) before swapping in the real page content.
    private func endPageDrag(deltaX: CGFloat, velocity: CGFloat) {
        guard let container = dragOverlayContainer else { return }
        let width = max(container.bounds.width, 1)
        let distanceThreshold = width * 0.3
        let flickVelocityThreshold: CGFloat = 400 // points/sec

        var targetPage = currentPage
        if (deltaX <= -distanceThreshold || velocity <= -flickVelocityThreshold), dragHasNext {
            targetPage = currentPage + 1
        } else if (deltaX >= distanceThreshold || velocity >= flickVelocityThreshold), dragHasPrev {
            targetPage = currentPage - 1
        }

        let targetTranslation: CGFloat = targetPage > currentPage ? -width : (targetPage < currentPage ? width : 0)
        let distanceRemaining = targetTranslation - deltaX
        // apple-design's velocity handoff: relative velocity = gesture
        // velocity / remaining distance to the target, so the spring
        // continues at the same rate the fingers were already moving
        // instead of a visible seam between drag and animation.
        let relativeVelocity = abs(distanceRemaining) > 1 ? velocity / distanceRemaining : 0

        let spring = Self.springAnimation(
            keyPath: "transform.translation.x",
            from: deltaX,
            to: targetTranslation,
            damping: 1.0,
            response: 0.32,
            initialVelocity: relativeVelocity
        )
        container.layer?.add(spring, forKey: "pageDragSettle")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.layer?.setValue(targetTranslation, forKeyPath: "transform.translation.x")
        CATransaction.commit()

        let settleDuration = spring.settlingDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDuration) { [weak self] in
            // `DispatchQueue.asyncAfter`'s closure isn't provably
            // main-actor-isolated to the compiler even though it always
            // runs on the main queue here — same reasoning as the
            // `NSAnimationContext` completion hops elsewhere in this file.
            Task { @MainActor in
                self?.finishPageDrag(targetPage: targetPage)
            }
        }
    }

    private func finishPageDrag(targetPage: Int) {
        currentPage = targetPage
        collectionView.isHidden = false
        collectionView.reloadData()
        pageControl.currentPage = currentPage
        dragOverlayContainer?.removeFromSuperview()
        dragOverlayContainer = nil
        activeSnapshotDataSources.removeAll()
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
        activeSnapshotDataSources.append(dataSource)
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
    /// the exact same production methods with synthetic input (a fast
    /// flick past the commit threshold) so at least the state-machine
    /// transition (current page -> next page, no crash) can be confirmed
    /// via `log stream` — not a substitute for real hands-on trackpad
    /// verification, which the drag's actual visual feel still needs.
    public func debugSimulatePageDrag() {
        guard model.pages.count > 1 else {
            DiagnosticsLog.launcher.info("debugSimulatePageDrag: only \(self.model.pages.count, privacy: .public) page(s), nothing to drag between")
            return
        }
        let startPage = currentPage
        DiagnosticsLog.launcher.info("debugSimulatePageDrag: starting at page \(startPage, privacy: .public)")
        beginPageDrag()
        let width = max(collectionView.bounds.width, 1)
        let steps = 10
        for step in 1...steps {
            updatePageDrag(deltaX: -width * 0.5 * CGFloat(step) / CGFloat(steps))
        }
        endPageDrag(deltaX: -width * 0.5, velocity: -900)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
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

    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        // Single click launches/opens — matches real Launchpad convention.
        guard let indexPath = indexPaths.first else { return }
        activate(at: indexPath)
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
