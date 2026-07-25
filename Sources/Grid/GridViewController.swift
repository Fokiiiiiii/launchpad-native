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
