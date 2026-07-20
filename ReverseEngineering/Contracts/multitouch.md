# MultitouchSupport — Tier 2 (build-gated private)

- Framework: `/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport`
- Resolution: `dlopen(RTLD_NOW)` + `dlsym`, never statically linked
- Verified on: macOS 26.5.1 (build 25F80), arm64, machine has 2 multitouch devices attached (built-in trackpad + at least one other, e.g. Magic Trackpad/Mouse)

## Symbols confirmed present (dlsym succeeded)

`MTDeviceCreateList`, `MTDeviceCreateDefault`, `MTRegisterContactFrameCallback`,
`MTUnregisterContactFrameCallback`, `MTDeviceStart`, `MTDeviceStop`, `MTDeviceRelease`.

## Signatures verified by actual call

| Symbol | Signature | Call result | Plausible? |
| --- | --- | --- | --- |
| `MTDeviceCreateList` | `@convention(c) () -> Unmanaged<CFArray>?` | non-null `CFArray`, count = 2 | yes (matches attached device count) |

## Signatures NOT yet call-verified

`MTDeviceCreateDefault`, `MTRegisterContactFrameCallback` (callback ABI — contact
frame struct layout is the highest-risk unverified piece here),
`MTUnregisterContactFrameCallback`, `MTDeviceStart`, `MTDeviceStop`, `MTDeviceRelease`.

**Before Phase 5 gesture recognition work begins:** register a real callback,
start one device, log raw contact frames (id, position, size, pressure/force,
state) for a real thumb+3-finger pinch, and freeze the observed struct layout
as a fixture — do not hand-write the `MTContactCallbackFunction` frame struct
from community headers without capturing at least one real frame on this OS
build. This is the single highest fragility risk in the whole app per the
research notes (sandboxing must be off; no App Store distribution applies
here anyway).

## Failure behavior

If `MTDeviceCreateList` returns null/empty or `dlopen` fails, the raw
multitouch trigger must report itself unavailable (diagnostic reason:
"no multitouch device" / "MultitouchSupport unavailable") without touching
any other trigger (hotkey, hot corner, F4 still function).
