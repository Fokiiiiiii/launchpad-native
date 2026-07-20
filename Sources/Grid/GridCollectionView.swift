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
