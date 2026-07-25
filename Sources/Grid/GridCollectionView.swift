import AppKit

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
    var onSwipePage: ((Int) -> Void)?
    /// Trackpad 2-finger horizontal swipe, tracked continuously once
    /// engaged (past `minimumEngageDistance`). `onSwipeChanged` fires with
    /// the *cumulative* delta since the gesture began (not a per-frame
    /// delta), so callers can drive an overlay's transform 1:1 with the
    /// fingers. `onSwipeEnded` additionally passes a simple velocity
    /// estimate (points per second, from the last few samples) for
    /// apple-design-style velocity handoff into a settle animation.
    var onSwipeBegan: (() -> Void)?
    var onSwipeChanged: ((CGFloat) -> Void)?
    var onSwipeEnded: ((CGFloat, CGFloat) -> Void)?
    /// Fires when a click lands within a cell's bounding box but outside its
    /// actual icon+label content — see `GridCellItem.contentHitTestFrame`.
    /// Treated the same as clicking the launcher's empty background: dismiss.
    var onBackgroundClick: (() -> Void)?

    /// Which axis a 2-finger swipe engaged on — horizontal was the only
    /// supported axis originally; vertical was added so up/down swipes page
    /// too (a real user ask: the grid has no vertical scroll content of its
    /// own to preserve, so this axis was free to repurpose). Both axes
    /// share one cumulative-delta pipeline: whichever axis's cumulative
    /// distance first clears `minimumEngageDistance` wins for the rest of
    /// the gesture, and its raw accumulated delta (not a converted/flipped
    /// value) feeds the same `onSwipeChanged`/`onSwipeEnded` callbacks
    /// `GridViewController` already treats as axis-agnostic. Direction
    /// mapping (which way is "next page") is an unverified judgment call
    /// for the vertical axis specifically — see the README disclosure.
    private enum SwipeAxis { case horizontal, vertical }

    private var swipeAccumulatedDeltaX: CGFloat = 0
    private var swipeAccumulatedDeltaY: CGFloat = 0
    private var swipeAxis: SwipeAxis?
    private var swipeEngaged = false
    private var recentSamples: [(delta: CGFloat, time: CFTimeInterval)] = []
    /// A single confirmed-horizontal `.changed` sample used to fire
    /// `onSwipeBegan` unconditionally last time — ambient trackpad jitter
    /// (resting fingers) could cross that bar trivially. Requiring the
    /// *cumulative* delta to clear this distance first is what actually
    /// distinguishes "the user is swiping" from incidental motion.
    private let minimumEngageDistance: CGFloat = 15

    /// A plain scroll-wheel mouse (non-Apple, or any mouse without a
    /// touch-sensitive surface) sends discrete wheel ticks with no
    /// `NSEvent.Phase` at all — previously swallowed by the trackpad-only
    /// guard below, so such mice couldn't page the grid at all. These ticks
    /// carry no phase to key a `.began`/`.changed`/`.ended` state machine
    /// off of, so a wall-clock cooldown replaces the phase-driven
    /// `swipeEngaged` latch used for trackpad gestures.
    private var lastDiscreteWheelPageChange: CFTimeInterval = 0
    private let discreteWheelCooldown: CFTimeInterval = 0.35

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
            // Not a trackpad gesture. Could still be a plain mouse's
            // discrete wheel tick (no phase info either way) — handle that
            // case explicitly instead of swallowing everything without a
            // phase. `hasPreciseScrollingDeltas` is false for legacy
            // notch-wheel mice and true for trackpads/Magic Mouse's
            // continuous surface, so this is a defensive second check
            // alongside the phase test above, not the primary discriminator.
            guard !event.hasPreciseScrollingDeltas else { return }
            // Most non-Apple mice only have a vertical wheel, so fall back
            // to scrollingDeltaY when there's no horizontal component —
            // this is what actually makes a plain mouse usable for paging.
            let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            guard delta != 0 else { return }
            let now = CACurrentMediaTime()
            guard now - lastDiscreteWheelPageChange > discreteWheelCooldown else { return }
            lastDiscreteWheelPageChange = now
            onSwipePage?(delta < 0 ? 1 : -1)
            return
        }

        switch event.phase {
        case .began:
            swipeAccumulatedDeltaX = 0
            swipeAccumulatedDeltaY = 0
            swipeAxis = nil
            swipeEngaged = false
            recentSamples.removeAll()
        case .changed:
            swipeAccumulatedDeltaX += event.scrollingDeltaX
            swipeAccumulatedDeltaY += event.scrollingDeltaY
            if !swipeEngaged {
                // Whichever axis's *cumulative* magnitude is currently
                // larger is the candidate — re-evaluated every sample until
                // engagement, so a gesture that starts diagonal but
                // straightens out still resolves to the axis it settles on.
                let candidateAxis: SwipeAxis = abs(swipeAccumulatedDeltaX) >= abs(swipeAccumulatedDeltaY) ? .horizontal : .vertical
                let candidateMagnitude = candidateAxis == .horizontal ? abs(swipeAccumulatedDeltaX) : abs(swipeAccumulatedDeltaY)
                guard candidateMagnitude >= minimumEngageDistance else { break }
                swipeAxis = candidateAxis
                swipeEngaged = true
                onSwipeBegan?()
            }
            guard let axis = swipeAxis else { break }
            let effectiveDelta = axis == .horizontal ? swipeAccumulatedDeltaX : swipeAccumulatedDeltaY
            let now = CACurrentMediaTime()
            recentSamples.append((effectiveDelta, now))
            if recentSamples.count > 6 {
                recentSamples.removeFirst(recentSamples.count - 6)
            }
            onSwipeChanged?(effectiveDelta)
        case .ended, .cancelled:
            if swipeEngaged, let axis = swipeAxis {
                let effectiveDelta = axis == .horizontal ? swipeAccumulatedDeltaX : swipeAccumulatedDeltaY
                onSwipeEnded?(effectiveDelta, Self.estimateVelocity(recentSamples))
            }
            swipeAccumulatedDeltaX = 0
            swipeAccumulatedDeltaY = 0
            swipeAxis = nil
            swipeEngaged = false
            recentSamples.removeAll()
        default:
            break
        }
    }

    /// Points-per-second estimate from the oldest and newest of the last
    /// few `.changed` samples — enough for apple-design-style velocity
    /// handoff into the settle spring without needing every frame.
    private static func estimateVelocity(_ samples: [(delta: CGFloat, time: CFTimeInterval)]) -> CGFloat {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return (last.delta - first.delta) / CGFloat(last.time - first.time)
    }
}
