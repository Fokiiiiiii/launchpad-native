# Tier 1 — Public API replacements confirmed present

These compiled successfully against the machine's SDK (Xcode 26.6, macOS 26.5
SDK), which for standard, non-underscored public API is itself sufficient
verification — no dlopen/dlsym needed since these are ordinary linked symbols.

| API | Framework | Availability compiled | Notes |
| --- | --- | --- | --- |
| `NSGlassEffectView` | AppKit | `macOS 26.0+` | Use as primary Liquid Glass surface (Phase 3). `contentView` subview z-order is not guaranteed per Apple's docs — do not stack ad-hoc subviews expecting fixed order. |
| `NSGlassEffectContainerView` | AppKit | `macOS 26.0+` | Merges nearby glass views for one composited draw; use when multiple glass surfaces are adjacent (e.g. grid + search field). |
| `SMAppService` | ServiceManagement | `macOS 13.0+` | Primary for login item / LaunchAgent / LaunchDaemon registration and `unregister()` in Phase 8. `SMJobBless`/`SMAuthorizedClients` are fallback-only for pre-13 compatibility, which is out of scope (macOS 26+ target) — so in practice `SMJobBless` should not be needed at all here. |
| `OSSystemExtensionRequest` / `OSSystemExtensionManager` | SystemExtensions | present | Primary for system extension activation/deactivation in Phase 8; cross-check with `systemextensionsctl list` during manual verification. |

## Not yet verified

Actual runtime behavior (registering a real `SMAppService` login item,
requesting a real system extension activation, rendering a real
`NSGlassEffectView` on screen) — this file only confirms the SDK exposes
these types on this toolchain. Behavioral verification happens in the phases
that use them (3 and 8).
