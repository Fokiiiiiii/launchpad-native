import Foundation

/// One trackpad contact, reduced to what the recognizer needs. Maps
/// directly from the verified `Finger` struct
/// (`ReverseEngineering/Contracts/multitouch.md`) at the call site.
public struct TouchSample: Sendable, Equatable {
    public let id: Int32
    public let x: Float
    public let y: Float
    public let size: Float

    public init(id: Int32, x: Float, y: Float, size: Float) {
        self.id = id
        self.x = x
        self.y = y
        self.size = size
    }
}

/// Detects the classic Launchpad-style gesture: four or five simultaneous
/// contacts whose average pairwise spread either *contracts* past a
/// threshold (fingers pinching together — fires `onPinchDetected`, meant to
/// open the launcher) or *expands* past a threshold relative to a stable
/// three-frame baseline (fingers spreading apart — fires `onSpreadDetected`,
/// meant to close it). Each direction fires once per gesture; a changed
/// contact set or an empty frame re-arms the recognizer.
///
/// History: this defaulted to 2 fingers for one iteration to dodge a
/// suspected conflict with the OS's own 4-finger Launchpad/Mission Control
/// handling — hands-on testing found 2-finger pinch collides with the much
/// more universal system pinch-to-zoom gesture instead, which is worse. Went
/// to 4 fingers (real Launchpad's own count), then to 3 per a later explicit
/// user request, then back to a 4/5-only picker (3 dropped as an option).
public final class PinchGestureRecognizer {
    private enum Phase: Equatable {
        case idle
        case baseline(count: Int, ids: Set<Int32>, stableFrames: Int, spreads: [Float])
        case tracking(count: Int, ids: Set<Int32>, initialSpread: Float)
        case firedClosing(count: Int, ids: Set<Int32>)
        case firedOpening(count: Int, ids: Set<Int32>)
    }

    private var phase: Phase = .idle
    private var closingRatio: Float
    private let openingRatio: Float
    private var acceptedContactCounts: Set<Int>
    private let baselineFrameCount: Int
    private let minimumStableFrameCount: Int

    /// `closingRatio` is the fraction of the gesture's *starting* spread
    /// that counts as "closed enough" to fire — e.g. 0.6 means the fingers
    /// must contract to within 60% of their starting distance apart.
    /// `openingRatio` is the multiple of the starting spread that counts as
    /// "spread enough" to fire — e.g. 1.35 means the fingers must move 35%
    /// farther apart than they started. `acceptedContactCounts` is optional so
    /// the old single-count initializer remains source-compatible; the raw
    /// multitouch trigger supplies the selected count.
    public init(
        closingRatio: Float = 0.6,
        openingRatio: Float = 1.35,
        requiredContactCount: Int = 4,
        acceptedContactCounts: Set<Int>? = nil,
        baselineFrameCount: Int = 3,
        minimumStableFrameCount: Int = 3
    ) {
        self.closingRatio = closingRatio
        self.openingRatio = openingRatio
        self.acceptedContactCounts = acceptedContactCounts ?? [requiredContactCount]
        self.baselineFrameCount = max(1, baselineFrameCount)
        self.minimumStableFrameCount = max(1, minimumStableFrameCount)
    }

    /// Fingers pinching together — intended to open the launcher.
    public var onPinchDetected: (() -> Void)?
    /// Fingers spreading apart — intended to close the launcher.
    public var onSpreadDetected: (() -> Void)?

    /// Changes the required contact count at runtime for callers using the
    /// original scalar API. Resets the baseline so a gesture captured under a
    /// previous count cannot carry over.
    public func updateRequiredContactCount(_ count: Int) {
        acceptedContactCounts = [count]
        phase = .idle
    }

    /// Changes the accepted contact set at runtime. The raw trigger uses this
    /// to switch the selected count without replacing the listener.
    public func updateAcceptedContactCounts(_ counts: Set<Int>) {
        acceptedContactCounts = counts
        phase = .idle
    }

    /// Changes the pinch threshold at runtime without replacing the
    /// recognizer. Resetting the phase prevents a gesture captured under the
    /// old threshold from firing unexpectedly after the slider moves.
    public func updateClosingRatio(_ ratio: Float) {
        guard ratio.isFinite else { return }
        closingRatio = min(max(ratio, 0.05), 0.95)
        phase = .idle
    }

    public func ingest(_ touches: [TouchSample]) {
        guard !touches.isEmpty else {
            phase = .idle
            return
        }
        let ids = Set(touches.map(\.id))
        guard acceptedContactCounts.contains(touches.count),
              ids.count == touches.count else {
            // A mismatched frame must terminate the old gesture. Keeping the
            // old baseline after a 4↔5 or contact-ID transition can otherwise
            // fire on the first frame of an unrelated gesture.
            phase = .idle
            return
        }

        let spread = Self.averagePairwiseDistance(touches)
        switch phase {
        case .idle:
            phase = .baseline(count: touches.count, ids: ids, stableFrames: 1, spreads: [spread])
        case .baseline(let count, let baselineIDs, let stableFrames, var spreads):
            guard count == touches.count, baselineIDs == ids else {
                phase = .baseline(count: touches.count, ids: ids, stableFrames: 1, spreads: [spread])
                return
            }
            let nextStableFrames = stableFrames + 1
            spreads.append(spread)
            let targetFrames = max(baselineFrameCount, minimumStableFrameCount)
            guard nextStableFrames >= targetFrames else {
                phase = .baseline(count: count, ids: ids, stableFrames: nextStableFrames, spreads: spreads)
                return
            }
            let baselineValues = spreads.suffix(baselineFrameCount)
            let baseline = baselineValues.reduce(0, +) / Float(baselineValues.count)
            guard baseline.isFinite, baseline > 0 else {
                // Stay in baseline collection until a non-degenerate frame
                // is available instead of allowing a zero threshold to fire.
                phase = .baseline(count: count, ids: ids, stableFrames: nextStableFrames, spreads: Array(baselineValues))
                return
            }
            phase = .tracking(count: count, ids: ids, initialSpread: baseline)
        case .tracking(let count, let trackingIDs, let initialSpread):
            guard count == touches.count, trackingIDs == ids else {
                phase = .baseline(count: touches.count, ids: ids, stableFrames: 1, spreads: [spread])
                return
            }
            guard initialSpread > 0 else { return }
            if spread <= initialSpread * closingRatio {
                phase = .firedClosing(count: count, ids: ids)
                onPinchDetected?()
            } else if spread >= initialSpread * openingRatio {
                phase = .firedOpening(count: count, ids: ids)
                onSpreadDetected?()
            }
        case .firedClosing(let count, let firedIDs), .firedOpening(let count, let firedIDs):
            guard count == touches.count, firedIDs == ids else {
                phase = .baseline(count: touches.count, ids: ids, stableFrames: 1, spreads: [spread])
                return
            }
        }
    }

    static func averagePairwiseDistance(_ touches: [TouchSample]) -> Float {
        var total: Float = 0
        var count = 0
        for i in 0..<touches.count {
            for j in (i + 1)..<touches.count {
                let dx = touches[i].x - touches[j].x
                let dy = touches[i].y - touches[j].y
                total += (dx * dx + dy * dy).squareRoot()
                count += 1
            }
        }
        return count > 0 ? total / Float(count) : 0
    }
}
