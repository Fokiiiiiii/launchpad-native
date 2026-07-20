import AppKit

/// Routes right-clicks to a per-item context menu. `NSCollectionView` has no
/// `menuForRepresentedObjectAt:` delegate hook, so this is the standard way
/// to build a context menu that depends on which cell was clicked.
final class GridCollectionView: NSCollectionView {
    var menuProvider: ((IndexPath) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        if !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
        }
        return menuProvider?(indexPath)
    }
}
