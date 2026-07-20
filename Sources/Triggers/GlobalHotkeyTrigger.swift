import Carbon.HIToolbox
import Diagnostics
import Foundation

/// System-wide hotkey via the Carbon Hot Key API (`RegisterEventHotKey`).
/// There is still no modern replacement for an arbitrary, global,
/// event-driven (non-polling) hotkey outside Carbon's HIToolbox — this is
/// the same mechanism widely-used utilities (Alfred, Rectangle, etc.) rely
/// on today; Carbon.framework as a whole is deprecated for application UI,
/// but these specific event-hotkey entry points remain functional.
@MainActor
public final class GlobalHotkeyTrigger {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let onTrigger: () -> Void
    private static let signature: OSType = fourCharCode("LPNH")

    public private(set) var registeredKeyCode: UInt32?
    public private(set) var registeredModifiers: UInt32?

    public init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    /// Registers (replacing any previous registration first). Returns
    /// `false` on failure — most commonly because the combo is already
    /// claimed system-wide, which the caller should surface as a conflict
    /// rather than silently ignore.
    @discardableResult
    public func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    UInt32(kEventParamDirectObject),
                    UInt32(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == GlobalHotkeyTrigger.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let trigger = Unmanaged<GlobalHotkeyTrigger>.fromOpaque(userData).takeUnretainedValue()
                trigger.onTrigger()
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            DiagnosticsLog.triggers.error("InstallEventHandler failed: \(handlerStatus, privacy: .public)")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            DiagnosticsLog.triggers.error("RegisterEventHotKey failed (likely a conflict): \(registerStatus, privacy: .public)")
            unregister()
            return false
        }

        registeredKeyCode = keyCode
        registeredModifiers = modifiers
        return true
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        registeredKeyCode = nil
        registeredModifiers = nil
    }

    // No deinit: Swift 6 deinit is always nonisolated, and these handles are
    // main-actor, non-Sendable state. Callers (TriggerCoordinator.stopAll())
    // call `unregister()` explicitly before releasing the last reference.
}

func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + OSType(scalar.value & 0xFF)
    }
    return result
}
