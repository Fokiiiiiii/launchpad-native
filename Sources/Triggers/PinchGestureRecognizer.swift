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

/// Detects the classic Launchpad-style gesture: a fixed number of
/// simultaneous contacts (default **3**, by explicit user request) whose
/// average pairwise spread either *contracts* past a threshold (fingers
/// pinching together — fires `onPinchDetected`, meant to open the launcher)
/// or *expands* past a threshold relative to the gesture's start (fingers
/// spreading apart — fires `onSpreadDetected`, meant to close it). Each
/// direction fires once per gesture; re-arms only once every finger lifts.
///
/// History: this defaulted to 2 fingers for one iteration to dodge a
/// suspected conflict with the OS's own 4-finger Launchpad/Mission Control
/// handling — hands-on testing found 2-finger pinch collides with the much
/// more universal system pinch-to-zoom gesture instead, which is worse. Went
/// to 4 fingers (real Launchpad's own count) with real bidirectional
/// open/close semantics (pinch to open, spread to close) rather than a
/// single toggle-only trigger, then to 3 per a later explicit user request.
/// Contact count and both ratios are parameters (not hardcoded) so they can
/// become user settings in a future round.
public final class PinchGestureRecognizer {
    private enum Phase: Equatable {
        case idle
        case tracking(initialSpread: Float)
        case firedClosing
        case firedOpening
    }

    private var phase: Phase = .idle
    private let closingRatio: Float
    private let openingRatio: Float
    private let requiredContactCount: Int

    /// `closingRatio` is the fraction of the gesture's *starting* spread
    /// that counts as "closed enough" to fire — e.g. 0.6 means the fingers
    /// must contract to within 60% of their starting distance apart.
    /// `openingRatio` is the multiple of the starting spread that counts as
    /// "spread enough" to fire — e.g. 1.4 means the fingers must move 40%
    /// farther apart than they started.
    public init(closingRatio: Float = 0.6, openingRatio: Float = 1.4, requiredContactCount: Int = 3) {
        self.closingRatio = closingRatio
        self.openingRatio = openingRatio
        self.requiredContactCount = requiredContactCount
    }

    /// Fingers pinching together — intended to open the launcher.
    public var onPinchDetected: (() -> Void)?
    /// Fingers spreading apart — intended to close the launcher.
    public var onSpreadDetected: (() -> Void)?

    public func ingest(_ touches: [TouchSample]) {
        guard touches.count == requiredContactCount else {
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
                phase = .firedClosing
                onPinchDetected?()
            } else if spread >= initialSpread * openingRatio {
                phase = .firedOpening
                onSpreadDetected?()
            }
        case .firedClosing, .firedOpening:
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
