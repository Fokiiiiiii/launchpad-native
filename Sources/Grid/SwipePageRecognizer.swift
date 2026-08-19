import AppKit
import Diagnostics

/// Turns trackpad scroll events into page changes.
///
/// Lifted verbatim out of `GridCollectionView`, which had it as a `scrollWheel`
/// override, so an opened folder can page by the same gesture and the same
/// numbers as the grid behind it. Nothing about the recognition changed in the
/// move: every threshold, phase-normalization branch and ordering below is the
/// one the grid has been shipping, including the ones whose doc comments record
/// specific ways they went wrong on real hardware.
///
/// It reads only `NSEvent` fields and its own state — it never touched any
/// collection-view API, which is what made it liftable at all.
@MainActor
final class SwipePageRecognizer {
    /// `onDiscretePage` fires with `-1`/`+1` for plain wheel ticks, which carry
    /// no continuous position to track. The other three describe one continuous
    /// gesture: `onChanged` receives the *cumulative* delta since it began (not
    /// a per-frame delta) so a caller can track it 1:1, and `onEnded` adds a
    /// points-per-second velocity estimate for handoff into a settle spring.
    struct Callbacks {
        var onDiscretePage: ((Int) -> Void)?
        var onBegan: (() -> Void)?
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: ((CGFloat, CGFloat) -> Void)?
    }

    var callbacks = Callbacks()

    /// Which axis a 2-finger swipe engaged on — horizontal was the only
    /// supported axis originally; vertical was added so up/down swipes page
    /// too (a real user ask: the grid has no vertical scroll content of its
    /// own to preserve, so this axis was free to repurpose).
    ///
    /// History: a first version picked "whichever axis's cumulative
    /// magnitude is currently larger" as the engage candidate, re-evaluated
    /// every sample. That was a real regression for the *existing*,
    /// long-working horizontal gesture: real fingers landing on a trackpad
    /// almost always produce a brief vertical blip before a horizontal
    /// swipe's sweep takes over, and if that blip alone crossed
    /// `minimumEngageDistance` in Y before X caught up, the axis locked as
    /// vertical for the *entire* gesture — the subsequent, clearly
    /// intentional horizontal motion kept accumulating into
    /// `swipeAccumulatedDeltaX` but was never read again, since the locked
    /// axis was already vertical. Confirmed via user report ("horizontal
    /// swipe stopped paging"). Fixed by giving horizontal unconditional
    /// priority — it engages the instant its own cumulative distance
    /// clears the threshold, exactly like before vertical support existed,
    /// with zero dependency on the concurrent Y value. Vertical only
    /// engages when it clearly dominates (more than double X's magnitude)
    /// *and* horizontal hasn't already claimed the gesture — a conservative
    /// bar specifically so it can't misfire on the same kind of incidental
    /// blip in the other direction.
    private enum SwipeAxis { case horizontal, vertical }

    private var swipeAccumulatedDeltaX: CGFloat = 0
    private var swipeAccumulatedDeltaY: CGFloat = 0
    private var swipeAxis: SwipeAxis?
    private var swipeEngaged = false
    private var swipeCompletedForGesture = false
    private var recentSamples: [(delta: CGFloat, time: CFTimeInterval)] = []
    /// A single confirmed-horizontal `.changed` sample used to fire
    /// `onSwipeBegan` unconditionally last time — ambient trackpad jitter
    /// (resting fingers) could cross that bar trivially. Requiring the
    /// *cumulative* delta to clear this distance first is what actually
    /// distinguishes "the user is swiping" from incidental motion.
    ///
    /// Lowered from `15` to `10`: the user found 15pt of required finger
    /// travel before a swipe engaged noticeably less responsive than it
    /// should feel — a real, reported complaint distinct from
    /// `discreteWheelCooldown` below (that's a separate anti-double-trigger
    /// debounce for discrete hardware wheel ticks, not a distance gate, and
    /// is unrelated to this fix). `10` is chosen to feel snappier while
    /// still sitting comfortably above the incidental resting-finger jitter
    /// this gate exists to reject (see doc comment above).
    private let minimumEngageDistance: CGFloat = 10

    /// A plain scroll-wheel mouse (non-Apple, or any mouse without a
    /// touch-sensitive surface) sends discrete wheel ticks with no
    /// `NSEvent.Phase` at all — previously swallowed by the trackpad-only
    /// guard below, so such mice couldn't page the grid at all. These ticks
    /// carry no phase to key a `.began`/`.changed`/`.ended` state machine
    /// off of, so a wall-clock cooldown replaces the phase-driven
    /// `swipeEngaged` latch used for trackpad gestures.
    private var lastDiscreteWheelPageChange: CFTimeInterval = 0
    private let discreteWheelCooldown: CFTimeInterval = 0.35

    /// A page fits entirely in the viewport (no horizontal scroll content),
    /// so this view has nothing to actually scroll — `scrollWheel` is
    /// overridden purely to recognize the swipe gesture and translate it
    /// into a page change, not to move any content.
    func handle(_ event: NSEvent) {
        let hasPhase = event.phase != [] || event.momentumPhase != []
        if !hasPhase && !event.hasPreciseScrollingDeltas {
            // Plain wheel ticks have no phase and no precise deltas.
            let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            guard delta != 0 else { return }
            let now = CACurrentMediaTime()
            guard now - lastDiscreteWheelPageChange > discreteWheelCooldown else { return }
            lastDiscreteWheelPageChange = now
            callbacks.onDiscretePage?(delta < 0 ? 1 : -1)
            return
        }

        // Trackpad drivers may put the useful samples in momentumPhase or
        // leave both phase fields empty. Normalize all of those forms into
        // the same continuous state machine instead of dropping the frames.
        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            swipeAccumulatedDeltaX = 0
            swipeAccumulatedDeltaY = 0
            swipeAxis = nil
            swipeEngaged = false
            swipeCompletedForGesture = false
            recentSamples.removeAll()
            DiagnosticsLog.grid.notice("scrollWheel: began/mayBegin")
        }

        let momentumOnly = event.phase == [] && event.momentumPhase != []
        let isChanged = event.phase.contains(.changed)
            || (momentumOnly && event.momentumPhase.contains(.changed) && !swipeCompletedForGesture)
            || (!hasPhase && event.hasPreciseScrollingDeltas && !swipeCompletedForGesture)
        if isChanged {
            swipeAccumulatedDeltaX += event.scrollingDeltaX
            swipeAccumulatedDeltaY += event.scrollingDeltaY
            if !swipeEngaged {
                // Horizontal gets priority. Vertical only engages when it
                // clearly dominates, so a landing blip cannot steal a
                // horizontal page gesture.
                if abs(swipeAccumulatedDeltaX) >= minimumEngageDistance {
                    swipeAxis = .horizontal
                    swipeEngaged = true
                    callbacks.onBegan?()
                    DiagnosticsLog.grid.notice("scrollWheel: engaged horizontal at cumulative dx=\(self.swipeAccumulatedDeltaX, privacy: .public)")
                } else if abs(swipeAccumulatedDeltaY) >= minimumEngageDistance
                    && abs(swipeAccumulatedDeltaY) > abs(swipeAccumulatedDeltaX) * 2 {
                    swipeAxis = .vertical
                    swipeEngaged = true
                    callbacks.onBegan?()
                    DiagnosticsLog.grid.notice("scrollWheel: engaged vertical at cumulative dy=\(self.swipeAccumulatedDeltaY, privacy: .public)")
                }
            }
            if let axis = swipeAxis {
                let effectiveDelta = axis == .horizontal ? swipeAccumulatedDeltaX : swipeAccumulatedDeltaY
                let now = CACurrentMediaTime()
                recentSamples.append((effectiveDelta, now))
                if recentSamples.count > 6 {
                    recentSamples.removeFirst(recentSamples.count - 6)
                }
                callbacks.onChanged?(effectiveDelta)
            }
        }

        let isEnded = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            || (momentumOnly && (event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)))
        guard isEnded, !swipeCompletedForGesture else { return }

        DiagnosticsLog.grid.notice("scrollWheel: ended/cancelled, engaged=\(self.swipeEngaged, privacy: .public), dx=\(self.swipeAccumulatedDeltaX, privacy: .public), dy=\(self.swipeAccumulatedDeltaY, privacy: .public)")
        if swipeEngaged, let axis = swipeAxis {
            let effectiveDelta = axis == .horizontal ? swipeAccumulatedDeltaX : swipeAccumulatedDeltaY
            callbacks.onEnded?(effectiveDelta, Self.estimateVelocity(recentSamples))
        }
        swipeAccumulatedDeltaX = 0
        swipeAccumulatedDeltaY = 0
        swipeAxis = nil
        swipeEngaged = false
        swipeCompletedForGesture = true
        recentSamples.removeAll()
    }

    /// Points-per-second estimate from the oldest and newest of the last
    /// few `.changed` samples — enough for apple-design-style velocity
    /// handoff into the settle spring without needing every frame.
    private static func estimateVelocity(_ samples: [(delta: CGFloat, time: CFTimeInterval)]) -> CGFloat {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return (last.delta - first.delta) / CGFloat(last.time - first.time)
    }}
