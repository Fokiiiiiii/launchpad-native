import AppKit
import Catalog
import Localization
import Persistence

/// Rasterizes one page of the grid into a static image, and builds the
/// overlay view that image is shown in during a drag.
///
/// Split out of `GridViewController` because it depends on none of that
/// controller's mutable state — given a page's items and the geometry to draw
/// them at, the result is fully determined. Both drag paths need it (the
/// trackpad page swipe and the item-drag edge peek), and each used to build
/// its own overlay `NSImageView` with an identical, hand-repeated frame
/// convention that a comment in one of them explicitly told the reader to keep
/// in sync with the other.
@MainActor
enum PageSnapshotRenderer {
    /// A permanently-parked offscreen window hosting the throwaway collection
    /// view while it draws.
    ///
    /// `cacheDisplay` only produces real pixels for a layer-backed view in a
    /// window that has been displayed at least once; otherwise it reports
    /// success and returns a fully transparent bitmap — a real diagnosed bug
    /// ("the next page isn't visible during the drag"). Ordered front once at
    /// creation and never out: doing it per gesture caused visible flicker.
    private static let hostWindow: NSWindow = {
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

    /// Renders `items` into an offscreen collection view laid out exactly like
    /// the live grid, and rasterizes it.
    ///
    /// Icons come from `IconCache.cachedIconIfAvailable` — a synchronous peek
    /// that returns nothing rather than waiting on a decode, since blocking
    /// here would delay the drag's first frame. Pages the user has already
    /// seen are normally warm; a never-seen page renders blank until the live
    /// grid takes over at the end of the drag, an accepted trade-off.
    static func render(
        items: [LayoutItem],
        model: GridModel,
        iconCache: IconCache,
        itemIdentifier: NSUserInterfaceItemIdentifier,
        iconSize: Double,
        visualScale: CGFloat,
        size: NSSize
    ) -> NSImage? {
        let tempLayout = PagedGridLayout()
        tempLayout.settings = model.gridSettings
        let tempCollectionView = NSCollectionView(frame: NSRect(origin: .zero, size: size))
        tempCollectionView.collectionViewLayout = tempLayout
        tempCollectionView.register(GridCellItem.self, forItemWithIdentifier: itemIdentifier)
        tempCollectionView.backgroundColors = [.clear]

        let dataSource = SnapshotDataSource(
            items: items,
            model: model,
            iconCache: iconCache,
            itemIdentifier: itemIdentifier,
            iconSize: iconSize,
            visualScale: visualScale
        )
        // Only needed for this synchronous render — nothing suspends between
        // here and the return — so holding it in a local is enough;
        // `NSCollectionView.dataSource` does not retain.
        tempCollectionView.dataSource = dataSource
        tempCollectionView.reloadData()

        hostWindow.setContentSize(size)
        hostWindow.contentView = tempCollectionView
        tempCollectionView.layoutSubtreeIfNeeded()
        tempCollectionView.displayIfNeeded()

        defer {
            hostWindow.contentView = nil
            // Shrink the window too. Clearing `contentView` releases the
            // collection view, but the window itself keeps a backing store
            // sized to the last snapshot — the full grid viewport, which on a
            // Retina display is (width x 2) * (height x 2) * 4 bytes retained
            // for the rest of the session. Only the size changes; the window
            // stays ordered front, per the note above.
            hostWindow.setContentSize(NSSize(width: 1, height: 1))
        }

        guard let bitmap = tempCollectionView.bitmapImageRepForCachingDisplay(in: tempCollectionView.bounds) else { return nil }
        tempCollectionView.cacheDisplay(in: tempCollectionView.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    /// Builds the overlay that shows a neighbouring page alongside the live
    /// grid during a drag.
    ///
    /// - Parameter direction: `+1` for the page to the right, `-1` for the left.
    /// - Parameter scrollViewFrame: the frame to mirror, in the coordinates of
    ///   the view this overlay will be added to. Deliberately the *scroll
    ///   view's* frame and not the collection view's: the collection view lives
    ///   inside the scroll view's clip view, which has its own scrolled
    ///   coordinate space.
    static func makeNeighborImageView(
        image: NSImage,
        direction: Int,
        pageWidth: CGFloat,
        scrollViewFrame: NSRect
    ) -> NSImageView {
        let xOffset = direction > 0 ? pageWidth : -pageWidth
        let imageView = NSImageView(frame: NSRect(
            x: scrollViewFrame.origin.x + xOffset,
            y: scrollViewFrame.origin.y,
            width: scrollViewFrame.width,
            height: scrollViewFrame.height
        ))
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.wantsLayer = true
        return imageView
    }
}

/// A minimal, throwaway data source for rendering one page's cells offscreen.
/// Deliberately separate from `GridViewController`'s own conformance (which
/// always reads `currentPage`), so snapshotting an *adjacent* page never has
/// to perturb the live grid's state.
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
            // Synchronous, cache-only icons, for the same reason as the app
            // case above: an async fetch would resolve after the snapshot has
            // already been captured and the temporary collection view torn
            // down.
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
