import AppKit

/// Routes right-clicks to a per-item context menu, and trackpad 2-finger
/// horizontal swipes to page navigation.
///
/// The swipe is a real user requirement, not a nice-to-have: a 2-finger
/// horizontal swipe is the same gesture Safari/Photos use for content
/// paging and does not collide with Mission Control's own Space-switching
/// gesture, which macOS binds to 3/4-finger swipes by default — a different
/// finger count, so there's no shared-gesture conflict here.
final class GridCollectionView: NSCollectionView {
    var menuProvider: ((IndexPath) -> NSMenu?)?
    /// Fires with `-1` (previous) or `+1` (next) once per completed swipe.
    var onSwipePage: ((Int) -> Void)?
    /// Fires when a click lands within a cell's bounding box but outside its
    /// actual icon+label content — see `GridCellItem.contentHitTestFrame`.
    /// Treated the same as clicking the launcher's empty background: dismiss.
    var onBackgroundClick: (() -> Void)?

    private var swipeAccumulatedDeltaX: CGFloat = 0
    private var swipeIsHorizontal = false
    private var swipeFired = false

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        if !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
        }
        return menuProvider?(indexPath)
    }

    /// Only forwards to normal NSCollectionView click handling (selection,
    /// drag initiation) when the click actually lands on a cell's rendered
    /// icon/label — not just anywhere in its much larger bounding box. A
    /// margin of a few points is added around the content so clicking right
    /// at an icon's edge still registers.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point),
           let cell = item(at: indexPath) as? GridCellItem {
            let localPoint = cell.view.convert(point, from: self)
            if cell.contentHitTestFrame.insetBy(dx: -10, dy: -10).contains(localPoint) {
                super.mouseDown(with: event)
                return
            }
        }
        onBackgroundClick?()
    }

    /// A page fits entirely in the viewport (no horizontal scroll content),
    /// so this view has nothing to actually scroll — `scrollWheel` is
    /// overridden purely to recognize the swipe gesture and translate it
    /// into a page change, not to move any content.
    override func scrollWheel(with event: NSEvent) {
        guard event.phase != [] || event.momentumPhase != [] else {
            // Not a trackpad gesture (e.g. a plain mouse wheel tick) — this
            // view has nothing to scroll, so just swallow it quietly.
            return
        }

        switch event.phase {
        case .began:
            swipeAccumulatedDeltaX = 0
            swipeFired = false
            swipeIsHorizontal = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
        case .changed:
            guard swipeIsHorizontal, !swipeFired else { break }
            swipeAccumulatedDeltaX += event.scrollingDeltaX
            let threshold: CGFloat = 60
            if swipeAccumulatedDeltaX <= -threshold {
                swipeFired = true
                onSwipePage?(1) // content moved left under the fingers -> next page
            } else if swipeAccumulatedDeltaX >= threshold {
                swipeFired = true
                onSwipePage?(-1) // content moved right -> previous page
            }
        case .ended, .cancelled:
            swipeAccumulatedDeltaX = 0
            swipeIsHorizontal = false
            swipeFired = false
        default:
            break
        }
    }
}
