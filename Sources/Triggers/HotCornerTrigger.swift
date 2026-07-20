import AppKit
import Diagnostics

public struct HotCornerConfig: Sendable {
    public var enabled: Bool
    public var requiredModifiers: NSEvent.ModifierFlags
    public var activationDelay: TimeInterval

    public init(enabled: Bool = false, requiredModifiers: NSEvent.ModifierFlags = [], activationDelay: TimeInterval = 0.15) {
        self.enabled = enabled
        self.requiredModifiers = requiredModifiers
        self.activationDelay = activationDelay
    }
}

/// Event-driven (not polling) hot-corner detection: rides `NSEvent`'s global
/// mouse-moved monitor, which only fires on real pointer movement, and
/// checks corner membership per display via `HotCornerGeometry`. A corner
/// re-arms only after the pointer is confirmed to have left every corner
/// (`HotCornerGeometry.hasExitedCorners`), so it fires once per visit, not
/// once per frame while parked in the corner.
@MainActor
public final class HotCornerTrigger {
    private var configs: [ScreenCorner: HotCornerConfig] = [:]
    private var monitor: Any?
    private var armedCorners: Set<ScreenCorner> = Set(ScreenCorner.allCases)
    private var pendingActivation: DispatchWorkItem?
    private let onActivate: () -> Void

    public init(onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
    }

    public func configure(_ configs: [ScreenCorner: HotCornerConfig]) {
        self.configs = configs
    }

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handleMouseMoved(event)
        }
        if monitor == nil {
            DiagnosticsLog.triggers.error("Global mouseMoved monitor unavailable (likely missing Accessibility/Input Monitoring permission)")
        }
    }

    public func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        pendingActivation?.cancel()
    }

    private func handleMouseMoved(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return }

        if HotCornerGeometry.hasExitedCorners(point, in: screen.frame) {
            armedCorners = Set(ScreenCorner.allCases)
            return
        }

        guard let corner = HotCornerGeometry.corner(at: point, in: screen.frame),
              armedCorners.contains(corner),
              let config = configs[corner],
              config.enabled,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(config.requiredModifiers) || config.requiredModifiers.isEmpty
        else { return }

        armedCorners.remove(corner)
        pendingActivation?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onActivate() }
        pendingActivation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.activationDelay, execute: work)
    }
}
