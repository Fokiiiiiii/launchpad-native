# SkyLight — Tier 2 (build-gated private)

- Framework: `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`
- Resolution: `dlopen(RTLD_NOW)` + `dlsym`, never statically linked
- Verified on: macOS 26.5.1 (build 25F80), arm64

## Symbols confirmed present (dlsym succeeded)

`SLSMainConnectionID`, `CGSMainConnectionID` (compat alias), `SLSCopyWindowsWithOptionsAndTags`,
`SLSGetWindowOwner`, `SLSGetWindowBounds`, `SLSGetWindowLevel`, `SLSSetWindowLevel`,
`SLSOrderWindow`, `SLSCopySpacesForWindows`, `SLSGetActiveSpace`,
`SLSManagedDisplayGetCurrentSpace`, `SLSCopyManagedDisplays`, `SLSCopyManagedDisplaySpaces`,
`SLSCopyActiveMenuBarDisplayIdentifier`.

## Signatures verified by actual call (not just symbol presence)

| Symbol | Signature | Call result | Plausible? |
| --- | --- | --- | --- |
| `SLSMainConnectionID` | `@convention(c) () -> Int32` | `1473423` | yes (WindowServer connection ids from a live process are always > 0) |
| `SLSGetActiveSpace` | `@convention(c) (Int32) -> UInt64` | `582` (given the cid above) | yes (nonzero space id) |

## Signatures NOT yet call-verified (symbol exists, argument/return types are the commonly cited ones, unconfirmed by an actual call)

`SLSCopyWindowsWithOptionsAndTags`, `SLSGetWindowOwner`, `SLSGetWindowBounds`,
`SLSGetWindowLevel`, `SLSSetWindowLevel`, `SLSOrderWindow`, `SLSCopySpacesForWindows`,
`SLSManagedDisplayGetCurrentSpace`, `SLSCopyManagedDisplays`, `SLSCopyManagedDisplaySpaces`,
`SLSCopyActiveMenuBarDisplayIdentifier`, `CGSMainConnectionID`.

**Do not wrap these for real use (Phase 7) until each has been called once with
its guessed signature against a real window/display and the result manually
cross-checked** (e.g. `SLSCopyWindowsWithOptionsAndTags` result count against
`CGWindowListCopyWindowInfo`'s public equivalent for the same process set).

## Usage rules

- Window activation: `SLSOrderWindow` only handles WindowServer ordering. It
  does NOT set key/main window or activate the owning app — pair it with
  `NSRunningApplication.activate` (Tier 1) for real focus semantics. Accessibility's
  `kAXRaiseAction` is the preferred first attempt for raising a specific
  foreign window (Phase 7); fall back to `SLSOrderWindow` only if that proves
  insufficient.
- Read-only enumeration (`SLSCopyWindowsWithOptionsAndTags`,
  `SLSCopySpacesForWindows`) is lower risk than anything that mutates window
  level/order — prioritize verifying those first in Phase 7.

## Failure behavior

`dlopen` returning `NULL` (framework missing/path changed) must degrade the
whole Window Browser capability to unavailable with a diagnostic reason, not
crash the app (per architecture rule: capability-level fail isolation).

## Phase 7 outcome: SkyLight wasn't needed for enumeration/activation after all

Before wrapping any of the above, `CGWindowListCopyWindowInfo` (Quartz Window
Services, fully public) and `SCShareableContent`/`SCScreenshotManager`
(ScreenCaptureKit, fully public, macOS 12.3+/14+) were tested directly on
this machine and found sufficient for real window enumeration, titles,
bounds, and thumbnail capture — no private SkyLight call needed. Window
activation/close/minimize also turned out not to need `SLSOrderWindow`: the
public Accessibility API (`AXUIElement` + `kAXRaiseAction`/`kAXPressAction`/
`kAXMinimizedAttribute`), matched to a `WindowInfo` by title+frame, plus
`NSRunningApplication.activate()` for app-level focus, covered everything
verified live (enumerated Brave Browser's real windows, captured a real
thumbnail, and activation genuinely brought it to the front).

This means none of the symbols above were wrapped for Phase 7. They remain
build-gated candidates for exactly one still-unimplemented capability: Space
association/movement (`SLSCopySpacesForWindows` et al.), since that's the
one thing with no public equivalent. If that capability is built later, the
"not yet call-verified" list above still applies — verify each call against
a real result (e.g. cross-check `SLSCopySpacesForWindows`'s claimed space ID
against `SLSGetActiveSpace`'s already-verified one) before trusting a
guessed signature.
