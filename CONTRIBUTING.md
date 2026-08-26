# Contributing to LaunchpadNative

## Build & test

See [README.md](README.md#build-and-run) for prerequisites and the exact
build/test commands (this project uses an out-of-iCloud `--scratch-path`
since it lives under `~/Documents`, which is iCloud-synced).

Before opening a PR:

```sh
SCRATCH=~/.cache/launchpad-native/build
swift build --scratch-path "$SCRATCH"
swift test --scratch-path "$SCRATCH"
```

## Scope of changes

- Keep PRs focused on one change at a time — this project was built in
  incremental, independently-buildable steps (see
  [`docs/engineering-log.md`](docs/engineering-log.md)), and PRs should follow
  the same discipline rather than bundling unrelated changes.
- Every phase leaves the project buildable and passing tests. A PR that
  doesn't should say so explicitly and why.

## Private/undocumented API changes

If your change touches anything in `Sources/*/` that calls a private or
undocumented system API (SkyLight, MultitouchSupport, low-level HID key
handling, etc.), you must:

1. Verify the call against a real signature/behavior on an actual machine —
   not from a community header or blog post alone. This project's rule
   throughout has been "verify before wrap."
2. Update the relevant file under `ReverseEngineering/Contracts/` with what
   you actually observed (symbol presence, a real call's result, the OS
   build you tested on).
3. If a public API can do the same job, prefer it — check
   `ReverseEngineering/Contracts/public-tier1.md` first.

A PR that adds a new private-API dependency without a corresponding
contract update will be asked to add one before merging.

## What this project won't accept

Per its own constraints (see `README.md`): no binary releases, no
DMG/installer, no Homebrew Cask, no auto-updater, no code-signing/
notarization infrastructure. This project is Git-clone-and-build-yourself
OSS by design — PRs that add packaging/distribution tooling outside that
model will be declined regardless of how well-implemented they are.

## Code style

No enforced linter/formatter is set up. Match the surrounding file's style
— this codebase favors explaining *why* in doc comments (a non-obvious
constraint, a real bug that was fixed, a trade-off that was made) over
restating *what* the code does.
