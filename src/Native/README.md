# Native audio libraries

The checked-in XCFrameworks in `../Vendor` are used directly by Xcode. Ordinary installation does not require Rust or recompiling libopus.

## Contents

- `RTC`: the pinned str0m-based engine, C ABI, locked dependencies and native tests.
- `Opus`: the C wrapper, source tests and the full libopus 1.6.1 source distribution.
- `../Vendor/Notices`: locked dependency inventory, license texts and Rust standard-library notices.

The app uses the independent TCP constructor. The library retains the original UDP ABI and regression tests as component compatibility coverage; the obsolete Swift phone/UDP transports are not part of this app.

## Opus source provenance

The bundled libopus source is the unmodified [Opus 1.6.1 release](https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz). Its archive SHA-256, published on the [official download page](https://opus-codec.org/downloads/), is:

```text
6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
```

All 482 included upstream files were verified against this archive during the source-publication audit. Forty-eight undownloaded cloud files were restored from that same release; the dependency version and bundled native binaries were unchanged.

## Rebuild

Install Xcode and select its developer directory. Install Rust's official rustup tool and the pinned toolchain:

```sh
rustup toolchain install nightly-2026-10-02 --profile minimal --component rust-src
bash scripts/build_native.sh
```

Run these commands from the repository root. Cargo downloads the versions pinned in `RTC/Cargo.lock`. The build uses watchOS `arm64` / `arm64_32`, and Watch simulator `arm64`, including `build-std` for the tier-3 targets. `WATCHDOT_BUILD_JOBS` controls parallelism and `WATCHDOT_NATIVE_BUILD_DIR` can place build products outside the checkout.

The rebuild copies finished libraries into the existing XCFramework layouts. It remaps private checkout/toolchain paths out of distributed libraries. It does not install the app, access a ChatGPT account, or create calls.

## Native tests

```sh
cargo +nightly-2026-10-02 test --locked --manifest-path src/Native/RTC/Cargo.toml
```

The synthetic RTC tests cover ICE, DTLS, authenticated media, ordered events, translated TCP peers, wrong-source rejection and candidate budgets without opening service sockets. They do not establish physical radio routing or audible quality.

The Opus C probe source is retained under `Opus/tests`. Rebuild the macOS Opus slice before linking that probe. libopus's upstream source, build scripts and license are included for reproducibility.
