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

/// Detects the Launchpad-style thumb+3-finger pinch: four simultaneous
/// contacts whose average pairwise spread contracts past a threshold,
/// firing once per gesture and re-arming only once every finger lifts.
///
/// Thumb-specific disambiguation (as opposed to "any 4 contacts closing
/// together") is not implemented yet — flagged as a follow-up in
/// `ReverseEngineering/Contracts/multitouch.md` pending a clean, isolated
/// gesture-capture fixture. In practice, four simultaneous trackpad
/// contacts contracting together is already a fairly specific motion.
public final class PinchGestureRecognizer {
    private enum Phase: Equatable {
        case idle
        case tracking(initialSpread: Float)
        case fired
    }

    private var phase: Phase = .idle
    private let closingRatio: Float

    /// `closingRatio` is the fraction of the gesture's *starting* spread
    /// that counts as "closed enough" to fire — e.g. 0.6 means the fingers
    /// must move to within 60% of their starting distance apart.
    public init(closingRatio: Float = 0.6) {
        self.closingRatio = closingRatio
    }

    public var onPinchDetected: (() -> Void)?

    public func ingest(_ touches: [TouchSample]) {
        guard touches.count == 4 else {
            if touches.isEmpty { phase = .idle }
            return
        }

        let spread = Self.averagePairwiseDistance(touches)
        switch phase {
        case .idle:
            phase = .tracking(initialSpread: spread)
        case .tracking(let initialSpread):
            guard initialSpread > 0 else { return }
            if spread <= initialSpread * closingRatio {
                phase = .fired
                onPinchDetected?()
            }
        case .fired:
            break
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
