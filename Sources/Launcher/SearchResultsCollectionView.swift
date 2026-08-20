import AppKit

/// The paged search surface has no context-menu needs (unlike
/// `Grid.GridCollectionView`), but it shares the exact same problem: since
/// the layout-matching fix made search cells size to the grid's real
/// per-cell size, a cell's clickable bounding box became far larger than
/// the icon it actually holds. Without a guard, clicking the visibly-empty
/// margin around an icon still selected/launched it — this mirrors
/// `GridCollectionView`'s `mouseDown` guard against `contentHitTestFrame`.
final class SearchResultsCollectionView: NSCollectionView {
    /// Fires when a click lands within a cell's bounding box but outside its
    /// actual icon+label content, or anywhere else in empty space — treated
    /// the same as clicking the launcher's empty background: dismiss.
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point),
           let cell = item(at: indexPath) as? AppIconCollectionViewItem {
            let localPoint = cell.view.convert(point, from: self)
            if cell.contentHitTestFrame.insetBy(dx: -10, dy: -10).contains(localPoint) {
                super.mouseDown(with: event)
                return
            }
        }
        onBackgroundClick?()
    }
}
