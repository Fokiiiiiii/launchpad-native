# F4 / Launch Panel key — HID-level constant

- Constant: `NX_KEYTYPE_LAUNCH_PANEL = 13`, defined in `<IOKit/hidsystem/ev_keymap.h>`
- This is a compile-time C constant, not a dynamically resolved symbol — no
  dlsym check applies; verification is "does code referencing it compile and
  match the documented value," confirmed here.

## Behavioral notes (not yet call-verified — Phase 5 work)

- macOS 26's user-facing labeling has shifted this physical key's meaning
  toward "Spotlight key" in Apple's own documentation, while the historical
  HID constant name (`NX_KEYTYPE_LAUNCH_PANEL`) is unchanged. Settings copy
  should describe this as "the Spotlight/Launchpad key" rather than assuming
  users think of it as "the Launchpad key."
- Capture path: `CGEventTapCreate` (via `CGEvent.tapCreate` in Swift) at
  `.cghidEventTap` location, `.listenOnly`, requesting `NX_SYSDEFINED` (raw
  value `14`; not exposed as a `CGEventType` enum case — must be passed as a
  raw mask bit). **Verified**: `ContractProbe` successfully created this tap
  from an unprivileged `swift run` process on this machine (build 25F80) —
  it returned non-null, meaning the *process/terminal* already holds Input
  Monitoring permission via TCC. This does **not** prove the eventual bundled
  `LaunchpadNative.app` will get the same result: a freshly bundled `.app`
  with a new bundle identifier is a distinct TCC subject and must request and
  be granted Input Monitoring separately (System Settings ▸ Privacy &
  Security ▸ Input Monitoring). Re-verify with the actual bundle before
  Phase 5 assumes this "just works." If a tap cannot be created, the fallback
  is `.cgSessionEventTap` with reduced guarantees — document as a capability
  downgrade, not a silent substitution.
- `NX_SYSDEFINED` event type and `NX_SUBTYPE_AUX_CONTROL_BUTTONS` subtype are
  the expected wire format for this and other special keys (volume, media,
  brightness) per community + Apple DTS sample code; the exact bit-packing in
  `misc.L[0]` needs to be captured from a real event on this machine (fixture
  test) before the classifier is written, not assumed from third-party code.

## Open work (tracked in open-items.md)

Actually installing a `CGEventTap` on this machine and capturing one real F4
press event has not been done yet — this file only freezes the constant
value and the documented (unverified-by-us) event shape.
