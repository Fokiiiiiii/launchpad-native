import AppKit
import Catalog
import Diagnostics
import Persistence
import SwiftUI

/// Shown inside a full-screen dimming backdrop when a folder is opened
/// (`GridViewController.openFolder`/`FolderOverlayBackdropView`) — this
/// controller only owns its own content (title + tile grid + glass card
/// background); the full-screen take-over presentation is entirely the
/// caller's concern. One of `Folder.pages` is shown at a time, with the same
/// dot/chevron control the main grid uses — matching how the system's own
/// Launchpad pages through a folder, and matching the data model, which has
/// always packed folders into pages of `GridSettings.folderGridSize`. An
/// earlier version flattened every page into one vertically scrolling list;
/// that hid the fact that some folders held pages packed past that capacity
/// (see `GridModel.normalizeFolderPages`).
///
/// The tile grid itself is real SwiftUI (`FolderOverlayGridContent`/
/// `FolderOverlayTileView`, hosted via `NSHostingView`), directly adapted
/// from the user-supplied design reference's own `FolderOverlay`/
/// `AppTile` — not a hand-translated AppKit/`NSCollectionView` reinterpretation
/// of its numbers. This follows the same lesson already applied to the
/// closed folder icon (`FolderIconView`): tuning AppKit geometry to
/// *approximate* the reference repeatedly fell short of the user's explicit
/// "寸分違わず同じものにできないの？" (can't you make it exactly,
/// pixel-for-pixel identical to the reference?) ask, whereas hosting the
/// reference's actual view code is identical by construction.
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
    private let gridModel = FolderOverlayGridModel()
    /// The main grid's own current icon size (`GridViewController.currentIconSize`)
    /// — a real design reference the user supplied directly asked for
    /// "内部アイコンが通常サイズの配置へ広がる" (contained icons expand to
    /// their normal size when the folder opens), which a fixed 56pt
    /// regardless of the grid's actual configured size did not satisfy.
    private let iconSize: Double
    /// The main grid's own column count (`GridSettings.columns`) — a real
    /// screenshot of a genuinely different app (confirmed by the user;
    /// its "その他" folder held system utilities that don't match this
    /// app's own data at all) showed the opened folder always using the
    /// *same* fixed column count as the closed grid itself, with rows
    /// growing/shrinking to fit — not a variable column count computed
    /// from the item count (this file's previous `sqrt(itemCount * 1.6)`
    /// heuristic), which the reference never does
    /// (`LazyVGrid(columns: Array(repeating: ..., count: metrics.columns))`
    /// — always exactly `metrics.columns`).
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

    // The card's own vertical layout, spelled out rather than folded into one
    // magic number. `updatePreferredContentSize` used to add a flat `88 + 70`,
    // which matched no actual measurement: it left ~39pt of dead space below a
    // single row (the card read as oddly tall for two apps) while being ~94pt
    // short for two rows, so the second row was clipped mid-icon with its
    // labels cut off — both reported ("小さい時の画面が微妙", "中身で
    // スクロールをしたりすると微妙").
    /// `FolderOverlayGridContent`'s own `.padding(.vertical, 34)`.
    private static let gridVerticalPadding: CGFloat = 34
    private static let titleTopInset: CGFloat = 14
    /// The reference's `VStack(spacing: 28)` between the title and the grid.
    private static let titleToGridGap: CGFloat = 28
    private static let cardBottomInset: CGFloat = 10
    /// How much of the screen the card may occupy before its content starts
    /// scrolling. The previous flat 480pt cap was set without reference to the
    /// display: on a 1050pt-tall screen it clipped a second row that had ample
    /// room to fit, and on a short screen it would have overflowed instead.
    ///
    /// Sized so the three rows a folder is laid out around (see
    /// `displayedColumnCount`) actually fit at the icon sizes this grid uses —
    /// at 0.62 the third row was still cut in half, which is the same clipping
    /// in a new place rather than a fix.
    private static let maximumHeightFraction: CGFloat = 0.80
    private static let pageControlHeight: CGFloat = 28
    /// How far a page slides as it leaves/enters, matching the main grid's own
    /// `pageSlideOffset`.
    private static let pageSlideOffset: CGFloat = 18
    /// The shape a folder is laid out around — see `displayedColumnCount`.
    private static let preferredRowCount = 3

    /// Three rows is what a folder is laid out around ("基本縦3段を基準にして
    /// 例えば3かけ3とかただ2かけ3とかはそのままでいい"), so the column count
    /// follows from the item count rather than from the main grid's own.
    ///
    /// Nine items become 3×3 and six become 2×3, instead of one long row of six
    /// with three stragglers underneath — which is what using the grid's column
    /// count produced, and why an opened folder stretched most of the way
    /// across the screen no matter how little was in it. Up to three items stay
    /// on one row; past three, columns grow while the height stays put. The
    /// main grid's column count still caps the result, so a very full folder
    /// gains a fourth row and scrolls rather than growing wider forever.
    static func displayedColumnCount(itemCount: Int, configuredColumns: Int) -> Int {
        let count = max(itemCount, 1)
        guard count > Self.preferredRowCount else { return count }
        let columns = Int(ceil(Double(count) / Double(Self.preferredRowCount)))
        return min(columns, max(configuredColumns, 1))
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func loadView() {
        let root = NSView()
        // `root`'s own outer frame is deliberately plain/frame-based (this
        // is the default — `translatesAutoresizingMaskIntoConstraints`
        // stays `true`), never Auto Layout, and the caller
        // (`GridViewController.openFolder`) sets `root.frame` directly
        // rather than via constraints. This sidesteps a real, confirmed
        // AppKit behavior: when a view controller's view *does* use pure
        // Auto Layout for its own outer geometry, `NSViewController`
        // automatically maintains its own width/height constraints mirroring
        // `preferredContentSize` (visible in a live constraint dump as
        // `'NSViewController.preferredContentSize.width'`) — and in one
        // confirmed real regression ("フォルダを開くと画面が半分になる" /
        // "フォルダのみためがひどすぎる"), that auto-mirrored constraint
        // intermittently won over an explicit, equal-or-higher-priority
        // caller-side constraint for `root`'s width, leaving the panel
        // rendered at its SwiftUI content's own narrower intrinsic size
        // instead of the intended screen-relative width — reproducibly, on
        // a fresh rebuild, regardless of priority tuning or explicitly
        // deactivating that constraint after the fact (both tried; neither
        // held). Never having `root` participate in Auto Layout for its own
        // frame in the first place removes the interaction entirely: Auto
        // Layout still governs everything *inside* `root` (background/
        // titleField/hosting/pageControl, all pinned to `root`'s bounds),
        // which works identically regardless of whether `root` itself is
        // frame- or constraint-positioned by its own superview.

        titleField.translatesAutoresizingMaskIntoConstraints = false
        // 21pt regular weight — the reference's own
        // `Text(folder.name).font(.system(size: TSLayout.folderTitleSize))`
        // has no explicit weight (defaults to regular).
        titleField.font = .systemFont(ofSize: 21, weight: .regular)
        titleField.alignment = .center
        // Editable in place, the way the system's own folder title is.
        //
        // `NSTextField(labelWithString:)` builds a cell that is neither
        // editable nor selectable, and this codebase has already lost a day to
        // exactly that: a field whose cell refuses to track a click falls back
        // to `super.mouseDown`, the click walks up the responder chain, and
        // whatever sits behind it acts on it instead — here that would be the
        // backdrop, so clicking the name would close the folder. Both flags are
        // set explicitly rather than relying on any convenience initializer.
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

        // Light, barely-tinted frosted-glass card background — a decorative
        // sibling behind the grid only (not the title, which floats
        // directly on the backdrop above it — see the constraint below).
        // Real, confirmed report ("フォルダの背景を再度表示させて"): this
        // was removed in an earlier pass under the mistaken belief it was
        // the "black background" a prior report meant; see
        // `GlassBackgroundHelper.makeFolderCardBackground`'s doc comment.
        let background = GlassBackgroundHelper.makeFolderCardBackground(cornerRadius: 34)
        background.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(background)
        root.addSubview(titleField)
        root.addSubview(hosting)
        root.addSubview(pageControl)

        let pageControlHeight = pageControl.heightAnchor.constraint(equalToConstant: Self.pageControlHeight)
        self.pageControlHeight = pageControlHeight

        NSLayoutConstraint.activate([
            // The card background covers the grid and the page dots, but not
            // the title — which floats directly on the backdrop above it.
            // Pinning `background` to `root`'s full bounds instead put the
            // title *inside* the same boxed card as the grid, a real,
            // confirmed regression ("その他の文字が枠内にはいてるのが気に
            // なる") from an earlier pass.
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

    /// Computes `preferredContentSize` — width is always exactly `panelWidth`
    /// (the caller's target, see its doc comment for why this must match
    /// exactly); only the height is derived here, from the fixed `columns`
    /// count (the main grid's own column count — see that property's doc
    /// comment for why this isn't a per-item-count heuristic) and the actual
    /// row count, capped at `maximumHeight`.
    ///
    /// Every term is a real distance in the layout above, so a folder that fits
    /// gets a card that ends exactly where its content does — no dead space
    /// under a single row, and no row clipped in half when a second one would
    /// have fitted.
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
                    // Real, confirmed bug: a fresh folder open has every icon
                    // start nil and trickle in one at a time as each
                    // `cache.icon(for:)` await resolves — each of these
                    // `@Published` writes re-renders `FolderOverlayGridContent`,
                    // and one debug-hook check (which happened to sample
                    // only twice, at 0ms and +300ms) missed that a mid-stream
                    // re-render can race Auto Layout's width-constraint
                    // resolution and leave `NSHostingView` measured against
                    // its own narrower SwiftUI-computed intrinsic size
                    // instead of the width imposed by its pinning to `root`
                    // — exactly the collapsed-column symptom, just
                    // intermittent depending on how many icons are still
                    // loading when a screenshot is taken. Forcing a
                    // synchronous layout pass after every trickle update
                    // makes the correct width win deterministically instead
                    // of depending on AppKit "eventually" reconciling it.
                    self.view.window?.layoutIfNeeded()
                }
            }
        }
        gridModel.tiles = tiles
        view.window?.layoutIfNeeded()
    }

    /// Real, confirmed report ("フォルダ内のアプリ移動が違和感がある...
    /// 下にある実装からそのまま持ってきて"): a plain drop-to-reorder
    /// (the previous, already-shipped implementation) landed correctly in
    /// the model but gave no feedback *while* dragging — unlike the main
    /// grid's `ItemDragSession`, where other icons visibly shift out of the
    /// way in real time. These four methods split "model" from "live
    /// preview" the same way `ItemDragSession` does: `model`/`layout.json`
    /// is touched exactly once, in `commitTileDrag()`, when a drop actually
    /// lands — never during hover. `gridModel.tiles` (the SwiftUI-visible
    /// array) is the live-preview surface instead: `hoverTileDrag` reorders
    /// *only* that array, under animation, as the drag passes over other
    /// tiles. Because the real model is never touched mid-drag, a cancelled
    /// drag reconciles for free — `cancelTileDrag()` just calls the
    /// existing `refresh()`, which rebuilds `gridModel.tiles` from
    /// `model.folders[folderID]`, untouched throughout.
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
