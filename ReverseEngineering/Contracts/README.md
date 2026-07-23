# Private/Public API Contracts

Each file here records what has actually been verified on a real machine for
one capability area, not what a reverse-engineered header merely claims.
`Tools/ContractProbe` (run via `swift run ContractProbe --scratch-path
~/.cache/launchpad-native/build`) produces the raw evidence; these documents
are the frozen interpretation of that evidence for a given OS build.

Rule: no wrapper in `Sources/PrivateAPI/` may call a symbol whose contract
file here is missing or marked unverified. Re-run `ContractProbe` and update
the affected contract whenever the target OS build changes.

## Verified on

- OS: macOS 26.5.1 (build 25F80)
- CPU: Apple Silicon (arm64)
- Verified: 2026-07-20

## Index

- [skylight.md](skylight.md) — Tier 2, window/space enumeration and ordering
- [multitouch.md](multitouch.md) — Tier 2, raw trackpad contact frames
- [launchservices.md](launchservices.md) — Tier 3, application catalog SPI
- [public-tier1.md](public-tier1.md) — Tier 1 public replacements confirmed present in this SDK
- [f4-hid.md](f4-hid.md) — HID-level F4/Launch Panel key constant
- [open-items.md](open-items.md) — Phase 1 work not yet verified
- [privileged-helper.md](privileged-helper.md) — Tier 1 public API, resolved not viable (SMAppService daemon registration fails without a paid Team ID)
