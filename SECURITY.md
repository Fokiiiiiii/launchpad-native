# Security Policy

LaunchpadNative is an individually-maintained open-source project with no
dedicated security team or paid support channel. There is no bug bounty.

## Reporting a vulnerability

Please open a GitHub Issue describing the problem. If the issue involves
something you'd rather not post publicly before a fix exists, use GitHub's
private vulnerability reporting feature on this repository (Security tab →
"Report a vulnerability") if it's enabled; otherwise, a normal issue is
fine — this project has no confidential user data or backend to protect,
and every reported issue will be triaged as time allows.

## Scope and known risk areas

This app deliberately uses several categories of undocumented or
security-sensitive system behavior, documented in
[`ReverseEngineering/Contracts/`](ReverseEngineering/Contracts/README.md):

- **Private/undocumented macOS APIs** (SkyLight, MultitouchSupport, raw HID
  key handling) — resolved via `dlopen`/`dlsym` at runtime, never statically
  linked, and every wrapped call has been verified against real behavior on
  a real machine before being used (see the Contracts directory for what
  was actually tested).
- **The Uninstall feature** (`Sources/Uninstall/`) reads and can move
  application-related files to the Trash. It never permanently deletes
  anything (`FileManager.trashItem`, never `removeItem`), never acts on
  anything it can't confidently attribute to the target app (see
  `RemovalPlanner`'s `owned`/`sharedRisk`/`unknown` classification), and
  never touches root-owned files — that path was tested and found not
  viable for this project's unsigned distribution model (see
  `ReverseEngineering/Contracts/privileged-helper.md`).
- **No code signing or notarization** — by explicit design (this is a
  Git-clone-and-build OSS project, not a distributed binary), so macOS's
  usual Gatekeeper/notarization protections don't apply to a local build.
  Only build and run code you've reviewed yourself, from a source you trust.

If you find a way any of the above could be made to act on a bundle or
path other than what the user selected, that's exactly the kind of report
this policy wants.
