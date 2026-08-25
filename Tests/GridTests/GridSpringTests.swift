import AppKit
import Testing
@testable import Grid

// MARK: rubber band

/// `ItemDrag.itemDragEdgePeekResistanceDimension`'s doc comment justifies its
/// value with two measured outputs — the whole argument for why the edge peek
/// is gentler than the linear formula it replaced rests on them. Pinning them
/// here means the claim can't quietly stop being true.
@Test @MainActor func rubberBandMatchesTheMeasuredValuesTheEdgePeekWasTunedAgainst() {
    let dimension = ItemDrag.itemDragEdgePeekResistanceDimension
    #expect(abs(GridSpring.rubberBand(70, dimension: dimension) - 14.8) < 0.1)
    #expect(abs(GridSpring.rubberBand(14, dimension: dimension) - 5.8) < 0.1)
}

/// The point of the formula: it keeps moving (never a hard stop) but the
/// further past the boundary you push, the less each extra point buys.
@Test func rubberBandAlwaysAdvancesButWithDiminishingReturns() {
    let dimension: CGFloat = 24
    var previousOutput: CGFloat = 0
    var previousGain = CGFloat.greatestFiniteMagnitude
    for overshoot in stride(from: CGFloat(10), through: 200, by: 10) {
        let output = GridSpring.rubberBand(overshoot, dimension: dimension)
        let gain = output - previousOutput
        #expect(gain > 0, "overshoot \(overshoot) did not advance")
        #expect(gain < previousGain, "overshoot \(overshoot) did not resist more than the step before it")
        previousOutput = output
        previousGain = gain
    }
}

@Test func rubberBandIsSymmetricAndPassesThroughZero() {
    #expect(GridSpring.rubberBand(0, dimension: 24) == 0)
    #expect(GridSpring.rubberBand(-40, dimension: 24) == -GridSpring.rubberBand(40, dimension: 24))
}

// MARK: spring

/// Damping ratio 1.0 must be exactly critical damping — the "settles without
/// overshooting" default this codebase uses for every non-momentum animation.
/// `CASpringAnimation` takes an absolute damping coefficient, so the ratio only
/// holds if the conversion keeps `damping² == 4·mass·stiffness`.
@Test func aDampingRatioOfOneProducesCriticalDamping() {
    for response in [CGFloat(0.12), 0.2, 0.32, 0.45] {
        let spring = GridSpring.animation(keyPath: "transform.scale", from: 0, to: 1, damping: 1.0, response: response)
        #expect(abs(spring.damping * spring.damping - 4 * spring.mass * spring.stiffness) < 0.001)
    }
}

/// Below 1.0 the spring must actually be underdamped (it overshoots), and
/// lower ratios must be bouncier — otherwise "damping 0.82 for momentum
/// interactions, 1.0 for everything else" is a distinction without a difference.
@Test func lowerDampingRatiosAreProgressivelyBouncier() {
    let ratios: [CGFloat] = [0.98, 0.9, 0.82, 0.7]
    let dampingCoefficients = ratios.map {
        GridSpring.animation(keyPath: "opacity", from: 0, to: 1, damping: $0, response: 0.2).damping
    }
    for ratio in ratios {
        let spring = GridSpring.animation(keyPath: "opacity", from: 0, to: 1, damping: ratio, response: 0.2)
        #expect(spring.damping * spring.damping < 4 * spring.mass * spring.stiffness, "ratio \(ratio) is not underdamped")
    }
    #expect(dampingCoefficients == dampingCoefficients.sorted(by: >))
}

/// Response is the knob callers actually reason in ("0.16 for a snappy reorder
/// preview, 0.45 for a settle"), so a smaller response has to mean a stiffer,
/// faster spring.
@Test func aShorterResponseProducesAStifferSpring() {
    let snappy = GridSpring.animation(keyPath: "opacity", from: 0, to: 1, damping: 1.0, response: 0.16)
    let relaxed = GridSpring.animation(keyPath: "opacity", from: 0, to: 1, damping: 1.0, response: 0.45)
    #expect(snappy.stiffness > relaxed.stiffness)
    #expect(snappy.settlingDuration < relaxed.settlingDuration)
}

@Test func theAnimationCarriesItsEndpointsAndVelocityThrough() {
    let spring = GridSpring.animation(
        keyPath: "transform.translation.x",
        from: 12,
        to: -30,
        damping: 0.86,
        response: 0.24,
        initialVelocity: 3.5
    )
    #expect(spring.keyPath == "transform.translation.x")
    #expect(spring.fromValue as? CGFloat == 12)
    #expect(spring.toValue as? CGFloat == -30)
    #expect(spring.initialVelocity == 3.5)
    // Without this the layer snaps back to its model value the instant the
    // animation is removed, which is the visible bug it guards against.
    #expect(spring.duration == spring.settlingDuration)
}

// MARK: velocity estimate

@Test func velocityIsTheAverageRateBetweenTwoSamples() {
    let velocity = GridSpring.estimateVelocity(from: 100, at: 10.0, to: 160, at: 10.2)
    #expect(abs(velocity - 300) < 0.001)
}

/// Both guards exist to stop a meaningless estimate from being handed to a
/// spring as initial velocity: samples a fraction of a frame apart blow up
/// under division, and samples seconds apart describe a drag that has paused.
@Test func implausibleSampleSpacingYieldsNoVelocity() {
    #expect(GridSpring.estimateVelocity(from: 0, at: 10.0, to: 50, at: 10.0005) == 0)
    #expect(GridSpring.estimateVelocity(from: 0, at: 10.0, to: 50, at: 11.5) == 0)
    #expect(GridSpring.estimateVelocity(from: nil, at: 10.0, to: 50, at: 10.1) == 0)
    #expect(GridSpring.estimateVelocity(from: 0, at: nil, to: 50, at: 10.1) == 0)
}

// MARK: - Page transition timing

/// The data swap is scheduled off the spring's own `response`, so the two have
/// to stay related. Waiting on `settlingDuration` instead — when the spring
/// stops *moving* rather than when it has visually arrived — was measured at
/// 417ms for a page that looked settled in about half that, and the page sat
/// showing its old contents for the difference.
@Test @MainActor func theDataSwapIsTimedFromTheSpringsResponse() {
    for response in [GridViewController.PageTransition.exitResponse,
                     GridViewController.PageTransition.entryResponse,
                     GridViewController.PageTransition.commitResponse] {
        let delay = GridViewController.PageTransition.swapDelay(response: response)
        #expect(delay >= Double(response), "the swap would land before the page does")
        #expect(delay <= Double(response) * 1.4, "the page would sit still waiting for the swap")
    }
}

/// Bounded at both ends: a response tuned very short must not swap so early
/// that the page is still visibly moving, and a long one must not leave the
/// page parked.
@Test @MainActor func theSwapDelayStaysWithinItsBounds() {
    #expect(GridViewController.PageTransition.swapDelay(response: 0.01) == 0.12)
    #expect(GridViewController.PageTransition.swapDelay(response: 10) == 0.5)
}

/// Overshoot at a page boundary reads as the transition catching rather than
/// as bounce, so these springs stay just short of critically damped.
@Test @MainActor func pageSpringsDoNotOvershoot() {
    #expect(GridViewController.PageTransition.damping >= 0.95)
    #expect(GridViewController.PageTransition.damping <= 1.0)
}
