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
    /// The global monitor never sees events sent to this app's own windows, and
    /// the launcher is one: with only the global one, the pointer leaving a corner
    /// over the open launcher was never noticed, so the corner stayed disarmed.
    private var localMonitor: Any?
    private var armedCorners: Set<ScreenCorner> = Set(ScreenCorner.allCases)
    private var pendingActivation: DispatchWorkItem?
    /// Invalidates delayed activations that have been cancelled by `stop()`
    /// or by leaving a corner. `DispatchWorkItem.cancel()` does not guarantee
    /// that an already-enqueued closure will never run, so the generation is
    /// checked again on MainActor immediately before invoking `onActivate`.
    private var activationGeneration = 0
    private let onActivate: () -> Void

    public init(onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
    }

    public func configure(_ configs: [ScreenCorner: HotCornerConfig]) {
        self.configs = configs
    }

    public func start() {
        // Each is registered once; a global monitor that could not be registered
        // (no permission yet) is tried again on the next `start()`.
        if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                // AppKit invokes global-monitor callbacks outside the actor
                // isolation of this `@MainActor` trigger. Hop explicitly before
                // touching any trigger state to avoid crossing the actor
                // boundary from an AppKit callback.
                Task { @MainActor [weak self] in
                    self?.handleMouseMoved(event)
                }
            }
            if monitor == nil {
                DiagnosticsLog.triggers.error("Global mouseMoved monitor unavailable (likely missing Accessibility/Input Monitoring permission)")
            }
        }
        installLocalMonitor()
    }

    func installLocalMonitor() {
        guard localMonitor == nil else { return }
        // Local monitors run on the main thread, so the event is handled where it
        // arrives: a task per mouse move over the launcher was work for nothing.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseMoved(event) }
            return event
        }
    }

    /// Test hook: whether the monitor for events sent to this app is installed.
    var hasLocalMonitor: Bool { localMonitor != nil }

    public func stop() {
        activationGeneration &+= 1
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        pendingActivation?.cancel()
        pendingActivation = nil
    }

    private func handleMouseMoved(_ event: NSEvent) {
        // No corner turned on: nothing to look at, and this runs on every move.
        guard configs.values.contains(where: \.enabled) || pendingActivation != nil else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return }

        if HotCornerGeometry.hasExitedCorners(point, in: screen.frame) {
            activationGeneration &+= 1
            pendingActivation?.cancel()
            pendingActivation = nil
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
        activationGeneration &+= 1
        let generation = activationGeneration
        pendingActivation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // The work item may still execute after cancellation. Re-check
            // the generation on MainActor so `stop()`/corner-exit wins any
            // race with the delayed callback before activation is emitted.
            Task { @MainActor [weak self] in
                guard let self, self.activationGeneration == generation else { return }
                self.pendingActivation = nil
                self.onActivate()
            }
        }
        pendingActivation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.activationDelay, execute: work)
    }
}
