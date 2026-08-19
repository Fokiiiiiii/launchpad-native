import AppKit
import Diagnostics

/// Routes right-clicks to a per-item context menu, and trackpad 2-finger
/// horizontal swipes to page navigation.
///
/// The swipe is a real user requirement, not a nice-to-have: a 2-finger
/// horizontal swipe is the same gesture Safari/Photos use for content
/// paging and does not collide with Mission Control's own Space-switching
/// gesture, which macOS binds to 3/4-finger swipes by default — a different
/// finger count, so there's no shared-gesture conflict here.
///
/// History: a first continuous, drag-tracked version of this swipe fired
/// an overlay takeover on the very first `.changed` sample that looked
/// even slightly more horizontal than vertical, with no minimum-distance
/// gate — incidental trackpad motion could trigger it, and combined with a
/// stuck-overlay failure mode this produced a real regression (the grid
/// going permanently blank, requiring a force-quit). This version keeps
/// continuous tracking (the user's explicit ask, tried a third time with
/// the user's informed consent after two prior failures in this exact
/// area) but requires the cumulative delta to cross `minimumEngageDistance`
/// before engaging at all — see `GridViewController`'s drag methods for
/// the other structural fix: the live grid is never hidden, so a stuck
/// drag state can no longer make content disappear.
final class GridCollectionView: NSCollectionView {
    var menuProvider: ((IndexPath) -> NSMenu?)?
    /// Fires with `-1` (previous) or `+1` (next) for a *discrete* mouse-wheel
    /// page change (see the discrete-wheel branch in `scrollWheel` below) —
    /// that hardware has no continuous position data, so there's nothing to
    /// drive a finger-tracked drag with; it just jumps.
    var onSwipePage: ((Int) -> Void)? {
        didSet { swipeRecognizer.callbacks.onDiscretePage = onSwipePage }
    }
    /// Trackpad 2-finger horizontal swipe, tracked continuously once
    /// engaged (past `minimumEngageDistance`). `onSwipeChanged` fires with
    /// the *cumulative* delta since the gesture began (not a per-frame
    /// delta), so callers can drive an overlay's transform 1:1 with the
    /// fingers. `onSwipeEnded` additionally passes a simple velocity
    /// estimate (points per second, from the last few samples) for
    /// apple-design-style velocity handoff into a settle animation.
    var onSwipeBegan: (() -> Void)? {
        didSet { swipeRecognizer.callbacks.onBegan = onSwipeBegan }
    }
    var onSwipeChanged: ((CGFloat) -> Void)? {
        didSet { swipeRecognizer.callbacks.onChanged = onSwipeChanged }
    }
    var onSwipeEnded: ((CGFloat, CGFloat) -> Void)? {
        didSet { swipeRecognizer.callbacks.onEnded = onSwipeEnded }
    }
    /// Fires when a click lands within a cell's bounding box but outside its
    /// actual icon+label content — see `GridCellItem.contentHitTestFrame`.
    /// Treated the same as clicking the launcher's empty background: dismiss.
    var onBackgroundClick: (() -> Void)?

    /// The gesture itself lives in `SwipePageRecognizer` so an opened folder
    /// can page by the same one. A page fits entirely in the viewport, so this
    /// view has nothing of its own to scroll — the override exists purely to
    /// feed the recognizer.
    private let swipeRecognizer = SwipePageRecognizer()

    override func scrollWheel(with event: NSEvent) {
        swipeRecognizer.handle(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        if !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
        }
        return menuProvider?(indexPath)
    }

    /// Fires on mouseDown when the click lands within a cell's real content
    /// area (not its full, often-larger bounding box). `GridViewController`
    /// drives its own press/lift/reorder/folder-candidate/page-turn state
    /// machine from here — see that type's "Item drag" section — rather
    /// than letting NSCollectionView's built-in selection+drag machinery
    /// handle it, since that machinery has no notion of live neighbor
    /// displacement, folder-candidate hover zones, or drag-triggered page
    /// turning (the user's explicit "iOS home screen" interaction ask).
    var onItemMouseDown: ((IndexPath, NSEvent) -> Void)?
    var onItemMouseDragged: ((NSEvent) -> Void)?
    var onItemMouseUp: ((NSEvent) -> Void)?

    /// Only recognizes a press on a cell's rendered icon/label — not just
    /// anywhere in its much larger bounding box. A margin of a few points is
    /// added around the content so clicking right at an icon's edge still
    /// registers. Deliberately never calls `super.mouseDown` for a content
    /// press: NSCollectionView's own selection/drag-session machinery is
    /// bypassed entirely in favor of the custom state machine above.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point),
           let cell = item(at: indexPath) as? GridCellItem {
            let localPoint = cell.view.convert(point, from: self)
            if cell.contentHitTestFrame.insetBy(dx: -10, dy: -10).contains(localPoint) {
                DiagnosticsLog.grid.notice("GridCollectionView.mouseDown: content hit at \(indexPath.item, privacy: .public)")
                onItemMouseDown?(indexPath, event)
                return
            }
        }
        DiagnosticsLog.grid.notice("GridCollectionView.mouseDown: background click at \(String(describing: point), privacy: .public)")
        onBackgroundClick?()
    }

    /// AppKit keeps routing mouseDragged/mouseUp to whichever view received
    /// the initiating mouseDown, for the duration of that press — standard
    /// NSResponder tracking behavior, no extra setup needed here.
    override func mouseDragged(with event: NSEvent) {
        // `.debug`, not `.notice`: this fires 60-120 times a second for the
        // whole duration of a drag, and `.notice` is persisted to the on-disk
        // unified log store — a fixed per-event cost on the most
        // latency-sensitive path in the app. `log stream --level debug` still
        // shows these when diagnosing drag behaviour.
        DiagnosticsLog.grid.debug("GridCollectionView.mouseDragged fired")
        onItemMouseDragged?(event)
    }

    override func mouseUp(with event: NSEvent) {
        DiagnosticsLog.grid.debug("GridCollectionView.mouseUp fired")
        onItemMouseUp?(event)
    }


}
