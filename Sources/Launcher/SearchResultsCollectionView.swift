import AppKit

/// The paged search surface. It has the same two needs as
/// `Grid.GridCollectionView`, for the same reasons.
///
/// Since the layout-matching fix made search cells size to the grid's real
/// per-cell size, a cell's clickable bounding box became far larger than the
/// icon it actually holds. Without a guard, clicking the visibly-empty margin
/// around an icon still selected/launched it — hence the `mouseDown` guard
/// against `contentHitTestFrame`.
///
/// A right-click on a result offers the same per-app menu the grid does; a
/// result that can only be launched, never inspected or renamed, is a dead end
/// the moment the user is searching rather than browsing.
final class SearchResultsCollectionView: NSCollectionView {
    /// Fires when a click lands within a cell's bounding box but outside its
    /// actual icon+label content, or anywhere else in empty space — treated
    /// the same as clicking the launcher's empty background: dismiss.
    var onBackgroundClick: (() -> Void)?

    /// Supplies the context menu for the result at an index path, mirroring
    /// `Grid.GridCollectionView.menuProvider`. Selection is left to the
    /// provider: search selection lives in the view model, not in
    /// `selectionIndexPaths`.
    var menuProvider: ((IndexPath) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return menuProvider?(indexPath)
    }

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
