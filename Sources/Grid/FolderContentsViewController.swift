import AppKit
import Catalog
import DesignSystem
import Diagnostics
import Persistence
import SwiftUI

final class FolderContentsViewController: NSViewController, NSTextFieldDelegate {
    private let model: GridModel
    private let folderID: FolderID
    private let iconCache: IconCache
    private let onLaunch: (ApplicationRecord) -> Void
    private let onItemDraggedOut: (Int, Int) -> Void

    private let titleField = NSTextField(labelWithString: "")
    /// Hosts one folder page at a time. Sized directly against `root` rather
    /// than living in a scroll view: a folder pages sideways now, the way the
    /// main grid does, so there is nothing left to scroll.
    private var gridHost: NSHostingView<FolderOverlayGridContent>?
    /// The same dot/chevron control the main grid uses, reused unchanged — it
    /// holds no reference to the grid, and hides its chevrons on its own when
    /// there is only one page.
    private let pageControl = PageControlView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
    private var pageControlHeight: NSLayoutConstraint?
    /// Which of `Folder.pages` is on screen.
    private var currentFolderPage = 0
    /// The same gesture the grid behind this pages with — see
    /// `SwipePageRecognizer`. Only the discrete and settled forms are wired up:
    /// the folder does not track the finger continuously the way the grid does,
    /// because that path is where this project's page paging has broken on real
    /// hardware before, and it is worth landing separately.
    private let swipeRecognizer = SwipePageRecognizer()
    /// How far a swipe must travel before it counts as a page change, matching
    /// the grid's own `pageDragCommitDistance`.
    private static let swipeCommitDistance: CGFloat = 20
    /// …or how fast, for a flick that never travels that far. Same value the
    /// grid uses.
    private static let swipeFlickVelocity: CGFloat = 400
    private let gridModel = FolderOverlayGridModel()
    private let iconSize: Double
    /// The main grid's own column count: an opened folder keeps the grid's
    /// columns and grows rows, rather than deriving columns from the item
    /// count (this file's earlier `sqrt(itemCount * 1.6)` heuristic).
    private let columns: Int
    /// The bounded outer-card width selected by `GridViewController.openFolder`,
    /// fed into `preferredContentSize.width` by `updatePreferredContentSize()`
    /// so the caller can read it back without duplicating layout metrics. See
    /// `loadView()`'s doc comment for why `root`'s own outer frame is set
    /// directly by the caller rather than via Auto Layout constraints.
    private let panelWidth: CGFloat
    /// The tallest the card may become before its content scrolls — derived
    /// from the screen by `maximumPanelHeight(availableHeight:)`, not a fixed
    /// number, so the same folder is not clipped on a large display.
    private let maximumHeight: CGFloat
    /// Matches the design reference's `LazyVGrid(..., spacing: 26)`
    /// exactly — the previous 16pt was an invented value, not taken from
    /// the reference.
    private static let cellSpacing: CGFloat = 26
    private static let gridHorizontalInset: CGFloat = 22
    private static let tileLabelAllowance: CGFloat = 56
    private static let minimumPanelWidth: CGFloat = 240
    private var itemHeight: CGFloat { CGFloat(iconSize) + 40 }

    // Spelled out rather than folded into one number. A flat `88 + 70` matched
    // no measurement: ~39pt of dead space under one row, ~94pt short for two,
    // so the second row was clipped mid-icon ("小さい時の画面が微妙").
    /// `FolderOverlayGridContent`'s own `.padding(.vertical, 34)`.
    private static let gridVerticalPadding: CGFloat = 34
    private static let titleTopInset: CGFloat = 14
    /// The reference's `VStack(spacing: 28)` between the title and the grid.
    private static let titleToGridGap: CGFloat = 28
    private static let cardBottomInset: CGFloat = 10
    /// Share of the screen the panel may occupy. Rather than clipping what does
    /// not fit, icons are drawn smaller (see `folderIconSize`) — a backstop for
    /// deep folders, since following the grid's columns keeps common cases well
    /// under it. Replaced a flat 480pt cap that ignored the display entirely.
    private static let maximumHeightFraction: CGFloat = 0.75
    /// What `itemHeight` adds to an icon for its label and the gap above it.
    private static let tileLabelAllowanceVertical: CGFloat = 40
    /// Title area plus the panel's own bottom inset, close enough to size
    /// against before the title field exists. `updatePreferredContentSize`
    /// measures the real title once there is one.
    private static let approximateChromeHeight: CGFloat = 77
    private static let pageControlHeight: CGFloat = 28
    /// How far a page slides as it leaves/enters, matching the main grid's own
    /// `pageSlideOffset`.
    private static let pageSlideOffset: CGFloat = 18
    static func displayedColumnCount(itemCount: Int, configuredColumns: Int) -> Int {
        min(max(itemCount, 1), max(configuredColumns, 1))
    }

    /// The size to draw an opened folder's icons at.
    ///
    /// Normally the grid's own size — the folder should look like the grid it
    /// came out of, which is what the reference launcher does. The cap only
    /// engages for a folder deep enough that its rows would otherwise take over
    /// the display; at the common one or two rows nothing is scaled at all.
    static func folderIconSize(gridIconSize: Double, rows: Int, availableHeight: CGFloat) -> Double {
        let rowCount = CGFloat(max(rows, 1))
        let budget = availableHeight * Self.maximumHeightFraction
            - (rowCount - 1) * Self.cellSpacing
            - 2 * Self.gridVerticalPadding
            - Self.approximateChromeHeight
        let perRow = budget / rowCount
        let fits = perRow - Self.tileLabelAllowanceVertical
        return min(gridIconSize, Double(max(fits, 48)))
    }

    static func maximumPanelHeight(availableHeight: CGFloat) -> CGFloat {
        max(availableHeight * Self.maximumHeightFraction, 320)
    }

    /// Always the width the chosen column count actually needs, bounded by the
    /// space available. There is no separate "wide" mode any more: it existed
    /// because the column count came from the main grid, so a folder with more
    /// items than columns had to be stretched to fit them — with columns now
    /// derived from the item count, the natural width is the correct one.
    static func panelWidth(availableWidth: CGFloat, columns: Int, iconSize: CGFloat) -> CGFloat {
        let naturalWidth = CGFloat(max(columns, 1)) * (max(iconSize, 1) + Self.tileLabelAllowance)
            + 2 * Self.gridHorizontalInset
        let maximumWidth = max(availableWidth, Self.minimumPanelWidth)
        return min(max(naturalWidth, Self.minimumPanelWidth), maximumWidth)
    }

    /// Flattened (folderPage, folderIndex, item) so "Remove from Folder" can
    /// address the exact underlying position.
    private var flattenedItems: [(page: Int, index: Int, item: LayoutItem)] = []
    /// Bumped on every `refresh()`; guards a still-in-flight async icon
    /// fetch from writing into `gridModel.tiles` after a *later* refresh
    /// has already replaced the array (same purpose as the
    /// `currentRequestKey` guard `GridCellItem` uses for cell reuse, but
    /// keyed to this controller's own single shared tile array instead of
    /// per-cell identity).
    private var refreshGeneration = 0

    init(
        model: GridModel,
        folderID: FolderID,
        iconCache: IconCache,
        iconSize: Double,
        columns: Int,
        panelWidth: CGFloat,
        maximumHeight: CGFloat,
        onLaunch: @escaping (ApplicationRecord) -> Void,
        onItemDraggedOut: @escaping (Int, Int) -> Void
    ) {
        self.model = model
        self.folderID = folderID
        self.iconCache = iconCache
        self.iconSize = iconSize
        self.columns = max(columns, 1)
        self.panelWidth = max(panelWidth, Self.minimumPanelWidth)
        self.maximumHeight = max(maximumHeight, 180)
        self.onLaunch = onLaunch
        self.onItemDraggedOut = onItemDraggedOut
        super.init(nibName: nil, bundle: nil)
        swipeRecognizer.callbacks.onDiscretePage = { [weak self] delta in
            self?.goToAdjacentPage(delta)
        }
        swipeRecognizer.callbacks.onEnded = { [weak self] delta, velocity in
            guard let self else { return }
            // A swipe leftward (negative delta) means "show me the next page",
            // matching the grid's own direction.
            let travelled = abs(delta) >= Self.swipeCommitDistance
            let flicked = abs(velocity) >= Self.swipeFlickVelocity
            guard travelled || flicked else { return }
            self.goToAdjacentPage(delta < 0 ? 1 : -1)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func loadView() {
        let root = FolderPanelRootView()
        root.onScroll = { [weak self] event in self?.swipeRecognizer.handle(event) }

        titleField.translatesAutoresizingMaskIntoConstraints = false
        // 21pt regular weight — the reference's own
        // `Text(folder.name).font(.system(size: TSLayout.folderTitleSize))`
        // has no explicit weight (defaults to regular).
        titleField.font = .systemFont(ofSize: 21, weight: .regular)
        titleField.alignment = .center
        // Editable in place. `labelWithString:` builds a cell that is neither
        // editable nor selectable, and a cell that refuses to track a click
        // falls back to `super.mouseDown` — the click then walks up to the
        // backdrop and closes the folder. Both flags are set explicitly.
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.delegate = self
        titleField.usesSingleLineMode = true
        titleField.cell?.wraps = false
        titleField.cell?.isScrollable = true
        // Matches the reference's own `.shadow(color: .black.opacity(0.5),
        // radius: 8, y: 2)` on the title text — AppKit's y-offset convention
        // is flipped relative to SwiftUI's (positive = up), so -2 here is
        // the same downward-cast shadow.
        let titleShadow = NSShadow()
        titleShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        titleShadow.shadowBlurRadius = 8
        titleShadow.shadowOffset = NSSize(width: 0, height: -2)
        titleField.shadow = titleShadow

        let hosting = NSHostingView(rootView: FolderOverlayGridContent(
            model: gridModel,
            columns: columns,
            iconSize: CGFloat(iconSize),
            onDragCancelled: { [weak self] in self?.cancelTileDrag() }
        ))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // Defense in depth alongside the explicit pinning below and the forced
        // layoutIfNeeded() calls in refresh() — never let SwiftUI's own
        // intrinsic-size measurement win a priority tie-break against the
        // imposed Auto Layout width. A folder that lost its firm width
        // proposal once rendered as a garbled vertical sliver instead of a
        // grid, so this is guarded from both sides.
        hosting.setContentCompressionResistancePriority(.required, for: .horizontal)
        hosting.wantsLayer = true
        gridHost = hosting

        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.onSelectPage = { [weak self] index in self?.goToPage(index) }
        pageControl.onPrevious = { [weak self] in self?.goToAdjacentPage(-1) }
        pageControl.onNext = { [weak self] in self?.goToAdjacentPage(1) }

        let background = GlassSurfaceFactory.makeCardBackground(
            cornerRadius: 26,
            tint: NSColor.white.withAlphaComponent(0.08),
            borderAlpha: 0.16,
            shadowOpacity: 0.35,
            shadowRadius: 30,
            shadowOffset: CGSize(width: 0, height: -12)
        )
        background.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(background)
        root.addSubview(titleField)
        root.addSubview(hosting)
        root.addSubview(pageControl)

        let pageControlHeight = pageControl.heightAnchor.constraint(equalToConstant: Self.pageControlHeight)
        self.pageControlHeight = pageControlHeight

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: hosting.topAnchor),
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            titleField.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.titleTopInset),
            titleField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            // Pinned directly to `root` — with the scroll view gone, this is
            // the firm width proposal SwiftUI needs, and `root`'s own frame is
            // set by the caller (see this method's doc comment above).
            hosting.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: Self.titleToGridGap),
            hosting.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            pageControl.topAnchor.constraint(equalTo: hosting.bottomAnchor),
            pageControl.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            pageControl.widthAnchor.constraint(equalToConstant: 200),
            pageControlHeight,
            pageControl.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.cardBottomInset)
        ])
        view = root
        refresh()
    }

    /// Width is exactly `panelWidth`; only the height is derived here, from the
    /// row count and capped at `maximumHeight`. Every term is a real distance in
    /// the layout above, so a folder that fits ends where its content does.
    private func updatePreferredContentSize() {
        // The fullest page, not this one: a card that shrank when the user
        // paged onto a half-empty last page would jump under the cursor.
        let itemCount = max(folderPages.map(\.count).max() ?? 0, 1)
        let rows = max(1, Int(ceil(Double(itemCount) / Double(columns))))
        let gridHeight = CGFloat(rows) * itemHeight
            + CGFloat(rows - 1) * Self.cellSpacing
            + 2 * Self.gridVerticalPadding
        let chromeHeight = Self.titleTopInset
            + titleField.intrinsicContentSize.height
            + Self.titleToGridGap
            + Self.cardBottomInset
        let pagingHeight = folderPages.count > 1 ? Self.pageControlHeight : 0
        let height = min(gridHeight + chromeHeight + pagingHeight, maximumHeight)
        preferredContentSize = NSSize(width: panelWidth, height: max(height, 180))
        pageControlHeight?.constant = pagingHeight
        pageControl.isHidden = folderPages.count <= 1
    }

    // MARK: - Paging

    /// Swaps the visible page, sliding the outgoing one out and the incoming
    /// one in from the direction of travel.
    ///
    /// Mirrors the main grid's own `jumpToPage`: a page is a *data swap*, not a
    /// scroll position — the same tiles are rebuilt for the new page while the
    /// host slides. Doing it as one continuous strip is what the main grid
    /// tried first and abandoned, so this deliberately does not.
    private func goToPage(_ index: Int) {
        let clamped = min(max(index, 0), folderPages.count - 1)
        guard clamped != currentFolderPage, let host = gridHost, let layer = host.layer else {
            currentFolderPage = clamped
            refresh()
            return
        }
        let direction: CGFloat = clamped > currentFolderPage ? -1 : 1
        currentFolderPage = clamped

        let exit = GridSpring.animation(
            keyPath: "transform.translation.x",
            from: 0,
            to: direction * Self.pageSlideOffset,
            damping: 1.0,
            response: 0.20
        )
        layer.add(exit, forKey: "folderPageExit")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            host.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let host = self.gridHost, let layer = host.layer else { return }
                // Rebuilt while invisible, so the swap itself is never on screen
                // — the same ordering the main grid's page change relies on.
                self.refresh()
                self.view.layoutSubtreeIfNeeded()
                layer.add(
                    GridSpring.animation(
                        keyPath: "transform.translation.x",
                        from: -direction * Self.pageSlideOffset,
                        to: 0,
                        damping: 1.0,
                        response: 0.24
                    ),
                    forKey: "folderPageEnter"
                )
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.13
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    host.animator().alphaValue = 1
                }
            }
        }
    }

    private func goToAdjacentPage(_ delta: Int) {
        goToPage(currentFolderPage + delta)
    }

    /// Left/right arrows move between folder pages. The backdrop is first
    /// responder while a folder is open (that is what makes Escape close it),
    /// and it forwards unhandled keys down to this panel.
    func handleArrowKey(delta: Int) -> Bool {
        guard folderPages.count > 1 else { return false }
        goToAdjacentPage(delta)
        return true
    }

    /// Test hooks: a panel showing one page at a time has no other observable
    /// surface for "which page, and what is on it" — same reasoning as
    /// `PageControlView.dotButtonCountForTesting`.
    var pageCountForTesting: Int { folderPages.count }
    var visibleTileCountForTesting: Int { gridModel.tiles.count }
    var currentPageForTesting: Int { currentFolderPage }
    /// How many visible tiles have actually received an icon. Zero while a
    /// folder is still loading; zero *forever* is the signature of an icon
    /// fetch resolving against a controller nothing kept alive.
    var resolvedIconCountForTesting: Int { gridModel.tiles.filter { $0.icon != nil }.count }
    var titleForTesting: String {
        get { titleField.stringValue }
        set { titleField.stringValue = newValue }
    }

    /// The folder's own pages, or a single empty page if it has none.
    private var folderPages: [[LayoutItem]] {
        let pages = model.folders[folderID]?.pages ?? []
        return pages.isEmpty ? [[]] : pages
    }

    private func refresh() {
        // Never overwrite what the user is in the middle of typing — an icon
        // finishing its async load calls straight back into here.
        if titleField.currentEditor() == nil {
            titleField.stringValue = model.folders[folderID]?.name ?? "Folder"
        }
        flattenedItems = []
        if let folder = model.folders[folderID] {
            for (pageIndex, page) in folder.pages.enumerated() {
                for (itemIndex, item) in page.enumerated() {
                    flattenedItems.append((pageIndex, itemIndex, item))
                }
            }
        }
        // A page can disappear underneath the user — the last item on the last
        // page being dragged out is enough.
        currentFolderPage = min(max(currentFolderPage, 0), folderPages.count - 1)
        pageControl.numberOfPages = folderPages.count
        pageControl.currentPage = currentFolderPage
        updatePreferredContentSize()

        refreshGeneration += 1
        let generation = refreshGeneration
        let cache = iconCache

        var tiles: [FolderOverlayTile] = []
        for entry in flattenedItems where entry.page == currentFolderPage {
            guard case .app(let id) = entry.item, let record = model.record(for: id) else { continue }
            let tileID = record.iconCacheKey
            let cachedIcon = cache.cachedIconIfAvailable(for: record)
            tiles.append(FolderOverlayTile(
                id: tileID,
                name: model.displayName(for: record),
                icon: cachedIcon,
                onLaunch: { [weak self] in self?.onLaunch(record) },
                onOpenNewInstance: record.canOpenNewInstance ? { [weak self] in
                    self?.model.recordLaunch(for: record.id)
                    Task { await self?.model.save() }
                    AppLauncher.launch(record, createsNewInstance: true)
                } : nil,
                onShowInFinder: { NSWorkspace.shared.activateFileViewerSelecting([record.bundleURL]) },
                onRemoveFromFolder: { [weak self] in
                    guard let self else { return }
                    self.onItemDraggedOut(entry.page, entry.index)
                    self.refresh()
                },
                onDragStart: { [weak self] in self?.beginTileDrag(id: tileID) },
                onDragHoverEntered: { [weak self] in self?.hoverTileDrag(targetID: tileID) },
                onDropCommit: { [weak self] in self?.commitTileDrag() ?? false }
            ))
            if cachedIcon == nil {
                Task { @MainActor [weak self] in
                    let icon = await cache.icon(for: record)
                    guard let self, self.refreshGeneration == generation else { return }
                    guard let index = self.gridModel.tiles.firstIndex(where: { $0.id == tileID }) else { return }
                    self.gridModel.tiles[index].icon = icon
                    self.view.window?.layoutIfNeeded()
                }
            }
        }
        gridModel.tiles = tiles
        view.window?.layoutIfNeeded()
    }

    private static let tileDragHoverSpring = Animation.spring(response: 0.30, dampingFraction: 0.85)

    private func beginTileDrag(id: String) {
        gridModel.draggingID = id
        armFolderDragSafetyNet()
    }

    /// Live preview only — never touches `model`/`flattenedItems` (the real,
    /// persisted order). Matches the same same-page restriction the
    /// original drop-to-reorder already enforced: a tile whose real home
    /// page differs from the dragged tile's real home page is never a valid
    /// preview target.
    private func hoverTileDrag(targetID: String) {
        guard let draggedID = gridModel.draggingID, draggedID != targetID,
              isSamePage(draggedID, targetID),
              let fromIndex = gridModel.tiles.firstIndex(where: { $0.id == draggedID }),
              let toIndex = gridModel.tiles.firstIndex(where: { $0.id == targetID })
        else { return }
        withAnimation(Self.tileDragHoverSpring) {
            gridModel.tiles.insert(gridModel.tiles.remove(at: fromIndex), at: toIndex)
        }
    }

    /// Fires from *any* tile's drop — deliberately doesn't care which tile
    /// the drop physically landed on; wherever the live preview above has
    /// already moved `draggingID` to IS the final position to persist.
    @discardableResult
    private func commitTileDrag() -> Bool {
        defer { gridModel.draggingID = nil; disarmFolderDragSafetyNet() }
        guard let draggedID = gridModel.draggingID,
              let from = flattenedItems.first(where: { tileID(for: $0.item) == draggedID }),
              let toIndex = pageLocalIndex(ofTileID: draggedID, page: from.page),
              toIndex != from.index
        else {
            cancelTileDrag()
            return false
        }
        model.moveItemWithinFolder(folderID, page: from.page, fromIndex: from.index, toIndex: toIndex)
        Task { await model.save() }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            refresh()
        }
        return true
    }

    /// Reconciliation path for a drag that ends without a valid drop
    /// (dragged out of the grid entirely, or the residual gap neither
    /// `DropDelegate` callback covers — see `armFolderDragSafetyNet`'s doc
    /// comment). Since the live preview above never touched `model`,
    /// rebuilding `gridModel.tiles` from it via the existing `refresh()` is
    /// always correct, regardless of how far the preview drifted.
    private func cancelTileDrag() {
        guard gridModel.draggingID != nil else { return }
        gridModel.draggingID = nil
        disarmFolderDragSafetyNet()
        withAnimation(Self.tileDragHoverSpring) {
            refresh()
        }
    }

    private func isSamePage(_ idA: String, _ idB: String) -> Bool {
        guard let a = flattenedItems.first(where: { tileID(for: $0.item) == idA }),
              let b = flattenedItems.first(where: { tileID(for: $0.item) == idB })
        else { return false }
        return a.page == b.page
    }

    /// `id`'s current index within the live-preview order (`gridModel.tiles`),
    /// restricted to just the tiles that really belong to `page` — the
    /// correct `toIndex` for `moveItemWithinFolder`'s single-page semantics
    /// (that API expects an index within `folder.pages[page]`, not a global
    /// flat index across every page the panel happens to display together).
    private func pageLocalIndex(ofTileID id: String, page: Int) -> Int? {
        let idsOnPage = Set(flattenedItems.filter { $0.page == page }.compactMap { tileID(for: $0.item) })
        return gridModel.tiles.map(\.id).filter(idsOnPage.contains).firstIndex(of: id)
    }

    private func tileID(for item: LayoutItem) -> String? {
        guard case .app(let id) = item, let record = model.record(for: id) else { return nil }
        return record.iconCacheKey
    }

    // MARK: - Renaming

    /// Commits the edited name. Fires on Return and on losing focus alike —
    /// clicking away from a half-typed name should keep it, not discard it,
    /// matching how renaming works elsewhere in the system.
    func controlTextDidEndEditing(_ obj: Notification) {
        commitTitleEdit()
    }

    /// Split out of the delegate callback so the rule itself is reachable from
    /// a test without synthesizing an editing session.
    func commitTitleEdit() {
        let typed = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = model.folders[folderID]?.name ?? ""
        guard !typed.isEmpty else {
            // An empty name is not a rename — put the old one back.
            titleField.stringValue = current
            return
        }
        guard typed != current else { return }
        model.renameFolder(folderID, to: typed)
        Task { await model.save() }
    }

    // MARK: - Drag safety net

    private var folderDragGlobalMouseUpMonitor: Any?

    /// Mirrors `GridViewController`'s own established `itemDragGlobalMouseUpMonitor`
    /// pattern for the same reason it exists there: `DropDelegate` has no
    /// callback for "the drag ended and nothing was ever dropped anywhere"
    /// — `FolderGridOuterDropDelegate.dropExited` catches leaving the grid
    /// entirely, but Escape (or any other path where the drag session ends
    /// while still hovering *inside* the grid, over empty space rather than
    /// a tile) isn't covered by any `DropDelegate` callback at all.
    private func armFolderDragSafetyNet() {
        guard folderDragGlobalMouseUpMonitor == nil else { return }
        folderDragGlobalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            // A real performDrop is delivered synchronously with the same
            // mouseUp on the success path — this brief delay lets that win
            // the race before assuming the drag was abandoned.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let self, self.gridModel.draggingID != nil else { return }
                DiagnosticsLog.grid.notice("folder drag: mouseUp fired with no performDrop — reconciling to persisted order")
                self.cancelTileDrag()
            }
        }
    }

    private func disarmFolderDragSafetyNet() {
        if let monitor = folderDragGlobalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
        folderDragGlobalMouseUpMonitor = nil
    }
}

/// The panel's own root. Exists only so a scroll gesture that lands anywhere on
/// the band reaches the page recognizer: the tiles are SwiftUI inside an
/// `NSHostingView`, which has no scrollable content of its own and passes the
/// event up.
private final class FolderPanelRootView: NSView {
    var onScroll: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }
}
