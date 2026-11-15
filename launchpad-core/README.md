# launchpad-core

Build the static library before running `swift build` or `swift test` directly:

```sh
MACOSX_DEPLOYMENT_TARGET=15.0 cargo build --manifest-path launchpad-core/Cargo.toml --target-dir .build/rust --release --locked
```

`Scripts/build-app.sh` performs this step automatically. The library is linked from `.build/rust/release` and is not checked into the repository.
