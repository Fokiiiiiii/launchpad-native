# Privileged Helper (SMAppService daemon) — resolved: not viable

- Framework: `ServiceManagement` (public, `SMAppService`, macOS 13+)
- Verified on: macOS 26.5.1 (build 25F80), arm64, this machine
- Verified: 2026-07-23

## Question

Phase 8 (Complete Uninstall) needs to remove root-owned artifacts
(`/Library/LaunchAgents`, `/Library/LaunchDaemons`, package receipts) that a
non-privileged process can't touch. `SMAppService.daemon(plistName:)` is the
public, non-deprecated API for registering a privileged helper embedded in
the app bundle. This project is unsigned/unnotarized/no-paid-Developer-ID by
explicit requirement (see root `README.md`) — whether `SMAppService` daemon
registration works at all under that constraint was unverified before this
test (`open-items.md` previously listed it as "not started").

## Method

`Tools/PrivilegedHelperProbe` — a deliberately inert daemon payload: writes
one line (`euid` + timestamp) to a fixed `/tmp` path and exits. Never
touches app data or performs any removal; exists purely to prove whether
registration + real execution happens at all.

`Scripts/build-privileged-helper-fixture.sh` — builds a real release copy
of `LaunchpadNative.app`, embeds the daemon binary at
`Contents/MacOS/PrivilegedHelperProbe` and its launchd plist at
`Contents/Library/LaunchDaemons/com.launchpadnative.privilegedhelperprobe.plist`
(`BundleProgram` + `RunAtLoad`), then ad-hoc signs the whole bundle
(`codesign --sign - --force --deep`) — the only signing option available
under this project's no-paid-certificate constraint.

`Tools/PrivilegedHelperRegistrationProbe` — run from inside that signed
bundle (`Contents/MacOS/PrivilegedHelperRegistrationProbe`), calls
`SMAppService.daemon(plistName:).register()`, waits, checks
`launchctl print system/<label>` and the log file, then always calls
`.unregister()`.

## Result

```
Status before register(): SMAppServiceStatus(rawValue: 3)
register() FAILED: Error Domain=SMAppServiceErrorDomain Code=1 "Operation not permitted"
```

Confirmed via `codesign -dv` on the bundle actually used:

```
Format=app bundle with Mach-O thin (arm64)
CodeDirectory ... flags=0x2(adhoc) ...
Signature=adhoc
TeamIdentifier=not set
```

Post-attempt confirmation that nothing was left behind:

```
$ launchctl print system/com.launchpadnative.privilegedhelperprobe
Bad request.
Could not find service "com.launchpadnative.privilegedhelperprobe" in domain for system
$ ls /tmp/launchpadnative-privileged-helper-probe.log
No such file or directory
```

`register()` fails immediately (`Operation not permitted`) before launchd
ever loads the daemon — the payload never ran, and no LaunchDaemon was left
registered on this machine.

## Conclusion

**Not viable under this project's distribution constraints.** `SMAppService`
daemon registration requires a real code-signing Team Identifier; an
ad-hoc signature (`TeamIdentifier=not set`, the only option without a paid
Apple Developer Program membership) is rejected outright. Since this
project is Git-only OSS with no signing/notarization by explicit
requirement, there is no path to a working Privileged Helper here — this
isn't a "not yet implemented" gap, it's a permanent limitation of the
distribution model itself.

**Consequence for Phase 8:** root-owned removal (`/Library`-domain
LaunchAgents/Daemons, package receipts) stays unimplemented, permanently.
`RemovalExecutor` (`Sources/Uninstall/RemovalExecutor.swift`) already
refuses every `requiresPrivilegedHelper` item with an explanatory outcome
rather than attempting it; the Settings Uninstall tab already only ever
offers to move `owned`, non-privileged items to Trash. No further
Privileged Helper work is planned.
