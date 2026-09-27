import AppKit
import Catalog
import Localization
import Persistence

/// The page beside the current one, shown next to the live grid while it is
/// dragged — by a trackpad page swipe, or by the item-drag edge peek.
///
/// This used to be a picture: a throwaway collection view laid out in an
/// offscreen window and rasterized with `cacheDisplay`, which draws the whole
/// page on the CPU. Measured on a 1680x900 page on a Retina display, that was
/// about 400ms — 90% of it in `cacheDisplay` — on the main thread at the first
/// frame of every swipe to a page not yet cached (the app's logs showed
/// 211–325ms between a swipe's direction being known and the next page
/// appearing), plus a 24MB bitmap per cached page. Shown as a view instead,
/// its cells are composited by Core Animation the same way the live grid's
/// are, and building it costs a reload and a layout pass.
@MainActor
enum NeighborPage {
    /// Builds page `items` laid out exactly like the live grid, over the
    /// scroll view. The caller moves it a page to either side with its layer's
    /// `transform.translation.x`, the same way it moves the live grid. Its
    /// frame stays over the grid: a layer's translation is invisible to
    /// AppKit, which therefore lays out and draws the page as a view on
    /// screen, and it is the arrangement the item-drag peek's arithmetic has
    /// always assumed (a page's width in the translation, none in the frame).
    ///
    /// - Parameter scrollViewFrame: the frame to mirror, in the coordinates of
    ///   the view this will be added to. Deliberately the *scroll view's* frame
    ///   and not the collection view's: the collection view lives inside the
    ///   scroll view's clip view, which has its own scrolled coordinate space.
    ///
    /// Icons come from `IconCache.cachedIconIfAvailable` — a synchronous peek
    /// that returns nothing rather than waiting on a decode. Neighbouring pages
    /// are prefetched as soon as a page settles, so they are normally warm; a
    /// cold one shows its missing icons empty until the live grid takes over
    /// at the end of the drag.
    ///
    /// The caller adds the result to its view and lays it out.
    static func makeView(
        items: [LayoutItem],
        model: GridModel,
        iconCache: IconCache,
        itemIdentifier: NSUserInterfaceItemIdentifier,
        iconSize: Double,
        visualScale: CGFloat,
        size: NSSize,
        scrollViewFrame: NSRect
    ) -> NSView {
        let layout = PagedGridLayout()
        layout.settings = model.gridSettings
        let collectionView = NSCollectionView(frame: NSRect(origin: .zero, size: size))
        collectionView.collectionViewLayout = layout
        collectionView.register(GridCellItem.self, forItemWithIdentifier: itemIdentifier)
        collectionView.backgroundColors = [.clear]
        let dataSource = NeighborPageDataSource(
            items: items,
            model: model,
            iconCache: iconCache,
            itemIdentifier: itemIdentifier,
            iconSize: iconSize,
            visualScale: visualScale
        )
        collectionView.dataSource = dataSource

        // In a scroll view set up like the live grid's: a collection view
        // outside one lays out no cells at all. Centred in the scroll view's
        // frame, the way the rasterized page was drawn into an image view the
        // size of that frame.
        let scrollView = NSScrollView(frame: NSRect(
            x: (scrollViewFrame.width - size.width) / 2,
            y: (scrollViewFrame.height - size.height) / 2,
            width: size.width,
            height: size.height
        ))
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        let view = NeighborPageView(frame: scrollViewFrame, dataSource: dataSource)
        view.wantsLayer = true
        view.addSubview(scrollView)
        collectionView.reloadData()
        return view
    }
}

/// Holds the page's data source — `NSCollectionView.dataSource` does not
/// retain — and stays out of the way of input: clicks and scrolls belong to
/// the live grid, and this is only ever a view of where the drag is heading.
private final class NeighborPageView: NSView {
    private let dataSource: NeighborPageDataSource

    init(frame: NSRect, dataSource: NeighborPageDataSource) {
        self.dataSource = dataSource
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A minimal data source for one neighbouring page. Deliberately separate from
/// `GridViewController`'s own conformance (which always reads `currentPage`),
/// so showing an *adjacent* page never has to perturb the live grid's state.
private final class NeighborPageDataSource: NSObject, NSCollectionViewDataSource {
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
            // Cache-only icons, for the same reason as the app case above.
            let records: [ApplicationRecord] = folder?.pages.flatMap { $0 }.compactMap { item in
                guard case .app(let id) = item else { return nil }
                return model.record(for: id)
            } ?? []
            let icons = Array(records.prefix(9)).compactMap { iconCache.cachedIconIfAvailable(for: $0) }
            cell.configureAsFolder(name: name, isSelected: false, iconSize: iconSize, visualScale: visualScale, icons: icons, requestKey: "folder:\(folderID.value)")
        }
        return cell
    }
}
