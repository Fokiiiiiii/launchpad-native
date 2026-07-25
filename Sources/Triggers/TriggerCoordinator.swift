import Diagnostics
import Persistence

public struct TriggerActivationReport: Sendable {
    public var hotkeyRegistered: Bool
    public var f4Active: Bool
    public var multitouchActive: Bool
}

/// Applies `TriggerSettings` to the four trigger mechanisms and forwards
/// every activation to one callback. Each trigger fails independently
/// (missing permission, no hardware, combo already claimed) without taking
/// the others down — capability-level isolation, same rule as
/// `PrivateAPIResolver`.
@MainActor
public final class TriggerCoordinator {
    private let hotkey: GlobalHotkeyTrigger
    private let hotCorner: HotCornerTrigger
    private let f4: F4Trigger
    private let multitouch: MultitouchGestureTrigger

    /// `onActivate` (toggle semantics) drives the hotkey/hot-corner/F4
    /// triggers. The multitouch gesture uses real Launchpad semantics
    /// instead — pinch closed opens, spread apart closes — so it takes
    /// separate `onPinchClose`/`onSpreadOpen` callbacks rather than a toggle.
    public init(onActivate: @escaping () -> Void, onPinchClose: @escaping () -> Void, onSpreadOpen: @escaping () -> Void) {
        hotkey = GlobalHotkeyTrigger(onTrigger: onActivate)
        hotCorner = HotCornerTrigger(onActivate: onActivate)
        f4 = F4Trigger(onActivate: onActivate)
        multitouch = MultitouchGestureTrigger(onPinchClose: onPinchClose, onSpreadOpen: onSpreadOpen)
    }

    @discardableResult
    public func apply(_ settings: TriggerSettings) -> TriggerActivationReport {
        hotkey.unregister()
        var hotkeyRegistered = false
        if settings.hotkeyEnabled, let keyCode = settings.hotkeyKeyCode {
            hotkeyRegistered = hotkey.register(keyCode: UInt32(keyCode), modifiers: UInt32(settings.hotkeyModifierFlags))
            if !hotkeyRegistered {
                DiagnosticsLog.triggers.error("Hotkey registration failed — likely claimed by another app or the system")
            }
        }

        hotCorner.configure(Self.hotCornerConfigs(from: settings))
        hotCorner.start()

        f4.stop()
        var f4Active = false
        if settings.f4Enabled {
            f4Active = f4.start()
        }

        multitouch.stop()
        multitouch.updateRequiredContactCount(settings.multitouchFingerCount)
        var multitouchActive = false
        if settings.multitouchGestureEnabled {
            multitouchActive = multitouch.start()
        }

        return TriggerActivationReport(hotkeyRegistered: hotkeyRegistered, f4Active: f4Active, multitouchActive: multitouchActive)
    }

    public func stopAll() {
        hotkey.unregister()
        hotCorner.stop()
        f4.stop()
        multitouch.stop()
    }

    private static func hotCornerConfigs(from settings: TriggerSettings) -> [ScreenCorner: HotCornerConfig] {
        var configs: [ScreenCorner: HotCornerConfig] = [:]
        for corner in ScreenCorner.allCases {
            let enabled = settings.hotCornersEnabled[corner.rawValue] ?? false
            configs[corner] = HotCornerConfig(enabled: enabled)
        }
        return configs
    }
}
