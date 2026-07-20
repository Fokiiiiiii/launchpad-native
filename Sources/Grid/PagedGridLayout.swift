import AppKit
import Persistence

/// A real custom `NSCollectionViewLayout` (not `NSCollectionViewFlowLayout`,
/// and never SwiftUI `LazyVGrid`, per the spec). Each NSCollectionView
/// *section* is one page; within a section, items are arranged in a fixed
/// `columns x rows` grid read from `GridSettings`, and pages are laid out
/// left-to-right as one continuous horizontally-scrollable strip — real
/// Launchpad's page model, minus the hand-tuned rubber-band/velocity paging
/// physics (tracked as a follow-up polish pass; functional paging via
/// scrolling and the page-jump API below is what Phase 4 requires).
final class PagedGridLayout: NSCollectionViewLayout {
    var settings: GridSettings = .default {
        didSet { invalidateLayout() }
    }

    private(set) var pageSize: NSSize = .zero
    /// The actual computed per-item cell size for the current bounds —
    /// exposed so cell content (the icon inside) can scale proportionally
    /// to its slot instead of using one fixed pixel size regardless of how
    /// large the grid's cells actually are.
    private(set) var currentCellSize: NSSize = .zero
    private var itemAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var contentSize: NSSize = .zero

    override func prepare() {
        guard let collectionView else { return }
        itemAttributes.removeAll(keepingCapacity: true)

        let viewportHeight = collectionView.bounds.height
        let pageWidth = collectionView.bounds.width
        pageSize = NSSize(width: pageWidth, height: viewportHeight)

        let columns = max(settings.columns, 1)
        let rows = max(settings.rows, 1)
        let hSpacing = CGFloat(settings.horizontalSpacing)
        let vSpacing = CGFloat(settings.verticalSpacing)
        let margin = CGFloat(settings.pageMargins)

        let availableWidth = pageWidth - margin * 2 - hSpacing * CGFloat(columns - 1)
        let availableHeight = viewportHeight - margin * 2 - vSpacing * CGFloat(rows - 1)
        let cellWidth = max(availableWidth / CGFloat(columns), 1)
        let cellHeight = max(availableHeight / CGFloat(rows), 1)
        currentCellSize = NSSize(width: cellWidth, height: cellHeight)

        let sectionCount = collectionView.numberOfSections
        for section in 0..<sectionCount {
            let pageOriginX = CGFloat(section) * pageWidth
            let itemCount = collectionView.numberOfItems(inSection: section)
            for item in 0..<itemCount {
                let column = item % columns
                let row = item / columns
                let x = pageOriginX + margin + CGFloat(column) * (cellWidth + hSpacing)
                let y = margin + CGFloat(row) * (cellHeight + vSpacing)
                let indexPath = IndexPath(item: item, section: section)
                let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
                attributes.frame = NSRect(x: x, y: y, width: cellWidth, height: cellHeight)
                itemAttributes[indexPath] = attributes
            }
        }
        contentSize = NSSize(width: pageWidth * CGFloat(max(sectionCount, 1)), height: viewportHeight)
    }

    override var collectionViewContentSize: NSSize { contentSize }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        itemAttributes.values.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        itemAttributes[indexPath]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.size != pageSize
    }

    /// The visible-rect origin for jumping directly to page `index`, used by
    /// both the page-dot control and cross-page keyboard navigation.
    func originForPage(_ index: Int) -> NSPoint {
        NSPoint(x: CGFloat(index) * pageSize.width, y: 0)
    }
}
