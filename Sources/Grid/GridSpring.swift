import AppKit

/// The motion math shared by the grid's two drag systems.
///
/// Page paging and item dragging each need the same three pieces — a spring
/// built from damping ratio and response, Apple's rubber-band resistance, and
/// a velocity estimate to hand off into the next spring — and both used to
/// reach for private statics on `GridViewController`. Keeping them here lets
/// the item-drag machinery live in its own type without either copying the
/// formulas or reaching back into the controller for them, and makes the
/// numbers directly testable.
enum GridSpring {
    /// Local copy of `LauncherWindowController`'s damping-ratio/response ->
    /// `CASpringAnimation` conversion (see apple-design's spring guidance):
    /// `Grid` sits *below* `Launcher` in the dependency graph (`Launcher`
    /// depends on `Grid`, not the reverse), so that helper can't be reused
    /// from here — duplicating this small formula locally is simpler than
    /// introducing a cross-module dependency inversion or a new shared
    /// target just for ~10 lines of math.
    static func animation(
        keyPath: String,
        from: CGFloat,
        to: CGFloat,
        damping dampingRatio: CGFloat,
        response: CGFloat,
        initialVelocity: CGFloat = 0
    ) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        let angularFrequency = 2 * .pi / response
        let stiffness = angularFrequency * angularFrequency
        animation.mass = 1
        animation.stiffness = stiffness
        animation.damping = 2 * dampingRatio * sqrt(stiffness)
        animation.initialVelocity = initialVelocity
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        animation.isRemovedOnCompletion = true
        return animation
    }

    /// Apple's standard rubber-band resistance formula (see apple-design's
    /// guidance): resistance increases with overshoot instead of a hard
    /// stop, so dragging past an end still moves but doesn't go far.
    static func rubberBand(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
        (overshoot * dimension * constant) / (dimension + constant * abs(overshoot))
    }

    /// Average velocity between two samples, in units per second.
    ///
    /// Returns 0 rather than a number for the two cases where an estimate
    /// would be meaningless: samples closer together than a frame (the
    /// division amplifies noise into an enormous velocity) and samples more
    /// than a second apart (the drag effectively paused, so the old sample
    /// says nothing about how fast it is moving now).
    static func estimateVelocity(
        from previousValue: CGFloat?,
        at previousTime: CFTimeInterval?,
        to currentValue: CGFloat,
        at currentTime: CFTimeInterval
    ) -> CGFloat {
        guard let previousValue, let previousTime, currentTime - previousTime > 0.001, currentTime - previousTime < 1.0 else { return 0 }
        return (currentValue - previousValue) / CGFloat(currentTime - previousTime)
    }
}
