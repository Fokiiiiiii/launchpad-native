---
name: Bug report
about: Something doesn't work the way it should
title: ""
labels: bug
---

**What happened**

**What you expected instead**

**Steps to reproduce**

1.
2.
3.

**Environment**
- macOS version:
- Mac model / chip (Apple Silicon required):
- Build config (`debug` or `-c release`):
- Did you build from a clean clone, or an existing checkout?

**Logs**

If relevant, attach output from:

```sh
log stream --predicate 'subsystem == "com.launchpadnative.app"' --style compact
```

**Anything else**

If this relates to a private/system API behaving differently on your
machine, please include your exact macOS build number (`sw_vers`) — this
project's `ReverseEngineering/Contracts/` are only verified against
specific OS builds and may need updating for yours.
