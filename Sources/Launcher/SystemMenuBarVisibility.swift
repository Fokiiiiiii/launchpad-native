import Darwin
import Foundation

/// Runtime boundary for the macOS 26 menu-bar visibility API. Symbols are
/// resolved dynamically so older systems can continue using the public
/// presentation-options fallback.
@MainActor
final class SystemMenuBarVisibility {
    private typealias MainConnectionID = @convention(c) () -> UInt32
    private typealias SetInsetAndAlpha = @convention(c) (
        UInt32,
        Double,
        Double,
        Float
    ) -> Int32

    private var mainConnectionID: MainConnectionID?
    private var setInsetAndAlpha: SetInsetAndAlpha?

    var isAvailable: Bool {
        mainConnectionID != nil && setInsetAndAlpha != nil
    }

    init() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { return }
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY | RTLD_LOCAL
        ) else { return }
        guard let connectionSymbol = dlsym(handle, "CGSMainConnectionID"),
              let visibilitySymbol = dlsym(handle, "CGSSetMenuBarInsetAndAlpha")
        else {
            dlclose(handle)
            return
        }

        // Keep the successful dlopen reference for the process lifetime so
        // both stored function pointers remain valid through termination.
        mainConnectionID = unsafeBitCast(connectionSymbol, to: MainConnectionID.self)
        setInsetAndAlpha = unsafeBitCast(visibilitySymbol, to: SetInsetAndAlpha.self)
    }

    /// Returns nil when the private API is unavailable, otherwise its native
    /// status code. Zero means the requested alpha was accepted.
    func setHidden(_ hidden: Bool) -> Int32? {
        guard let mainConnectionID, let setInsetAndAlpha else { return nil }
        return setInsetAndAlpha(mainConnectionID(), 0, 1, hidden ? 0 : 1)
    }
}
