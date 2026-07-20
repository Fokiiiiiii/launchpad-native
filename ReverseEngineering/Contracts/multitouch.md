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

## Contact frame struct — verified by live capture (Phase 5)

`Tools/MultitouchProbe` registered `MTRegisterContactFrameCallback` on both
devices and captured real frames on this machine (2026-07-20) while the user
touched the trackpad. The community-documented `Finger` struct layout was
confirmed correct — not assumed — by observing ~50 real touch events with
plausible values across every field:

```swift
struct MTPoint { var x: Float; var y: Float }
struct MTReadout { var position: MTPoint; var velocity: MTPoint }
struct Finger {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var foo3: Int32
    var foo4: Int32
    var normalized: MTReadout   // position.{x,y} in [0, 1]
    var size: Float
    var zero1: Int32
    var angle: Float            // radians
    var majorAxis: Float        // mm-scale, ~5-12 observed
    var minorAxis: Float
    var mm: MTReadout
    var zero2a: Int32
    var zero2b: Int32
    var unknown2: Float
}
```

Evidence: `position.{x,y}` stayed within [0, 1] for every touch; `size` was a
plausible small positive float; `majorAxis`/`minorAxis` fell in a consistent
~4-12 range matching a fingertip contact patch; `state` cycled through
values `{1, 3, 4, 5, 6, 7}` matching the widely-documented lifecycle
(1=starting, 3/4=touching, 5/6=breaking/lingering, 7=leaving) — internally
consistent across every observed finger's start-to-end sequence, not just a
one-off plausible read.

Callback registration used the plain (non-refcon) `MTContactCallbackFunction`
signature `(Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32`
— note the raw-pointer second parameter: `@convention(c)` rejected a typed
`UnsafeMutablePointer<Finger>?` parameter directly (Swift 6 compiler
restriction on the closure literal), so the callback takes a raw pointer and
rebinds it with `assumingMemoryBound(to: Finger.self)` inside.

**Not yet verified:** the exact thumb-vs-finger disambiguation this app's
gesture recognizer will need (identifying which contact is the thumb by
`majorAxis`/`size`/position, vs. an ordinary 4th finger) — the raw capture
above wasn't a clean, isolated single pinch gesture (background touches from
normal hand movement during the 15s window are mixed in), so the
*recognizer's* accuracy against a deliberate, isolated gesture is still
open. Tracked as a Phase 5 follow-up: capture a clean, isolated gesture
fixture once the recognizer exists, to validate against.

## Gesture design history: 4-finger → 2-finger → back to 4-finger, bidirectional

`PinchGestureRecognizer` originally defaulted to 4 simultaneous contacts
(thumb+3, matching Classic Launchpad's own gesture), firing a single
toggle. Live testing suspected a conflict with macOS's own Mission
Control/Launchpad-family multitouch handling and switched the default to a
**2-finger pinch**. Further hands-on testing found 2-finger pinch collides
with something far more universal instead — the system's own pinch-to-zoom
gesture — which is worse. The default is back to **4 fingers**
(`requiredContactCount: 4`), now with real bidirectional Launchpad semantics
implemented (previously only a single toggle existed): pinching the 4
contacts together fires `onPinchDetected` (opens the launcher), spreading
them apart fires `onSpreadDetected` (closes it) — matching how Classic
Launchpad's own trackpad gesture actually worked. Both ratios and the
contact count are constructor parameters, not hardcoded, so a future
Settings UI (Phase 6) could still offer a 2-finger toggle variant for users
who've disabled the system's competing gesture.

This also surfaced a real performance bug worth recording: the original
`MultitouchGestureTrigger.frameCallback` spawned a new
`Task { @MainActor in ... }` on *every* contact frame — which fires for any
trackpad touch at all (cursor movement, scrolling), not just the gesture
shape being matched. At typical multitouch frame rates that's continuous
Task/actor-hop churn system-wide while the trackpad is touched at all,
which is almost certainly what the user experienced as "very slow." Fixed
by running the recognizer synchronously on the callback's own thread
(guarded by a lock) and only hopping to the main actor once, on an actual
detected pinch.

## Failure behavior

If `MTDeviceCreateList` returns null/empty or `dlopen` fails, the raw
multitouch trigger must report itself unavailable (diagnostic reason:
"no multitouch device" / "MultitouchSupport unavailable") without touching
any other trigger (hotkey, hot corner, F4 still function).
