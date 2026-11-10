#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
native_root="$project_root/src/Native"
export WATCHDOT_NATIVE_BUILD_DIR="${WATCHDOT_NATIVE_BUILD_DIR:-$project_root/.build/native}"
export WATCHDOT_BUILD_JOBS="${WATCHDOT_BUILD_JOBS:-2}"
export CARGO_BUILD_JOBS="$WATCHDOT_BUILD_JOBS"
mkdir -p "$WATCHDOT_NATIVE_BUILD_DIR"
for target in 'watchos arm64 arm64_32' 'watchsimulator arm64'; do
 read -r -a native_parts <<< "$target"
 bash "$native_root/RTC/build.sh" "${native_parts[0]}" "$WATCHDOT_NATIVE_BUILD_DIR/rtc-${native_parts[0]}" "${native_parts[@]:1}"
done
for target in 'watchos arm64' 'watchos arm64_32' 'watchsimulator arm64'; do
 read -r -a native_parts <<< "$target"
 bash "$native_root/Opus/build.sh" "${native_parts[@]}"
done
xcrun lipo -create "$WATCHDOT_NATIVE_BUILD_DIR/opus-watchos-arm64/libWatchDotOpus.a" \
 "$WATCHDOT_NATIVE_BUILD_DIR/opus-watchos-arm64_32/libWatchDotOpus.a" -output "$WATCHDOT_NATIVE_BUILD_DIR/libWatchDotOpus-watchos.a"
for slice in watchos-arm64_arm64_32 watchos-arm64-simulator; do
 if [[ "$slice" == watchos-arm64_arm64_32 ]]; then
  native_rtc="$WATCHDOT_NATIVE_BUILD_DIR/rtc-watchos/libopenclaw_watch_rtc.a"
  native_opus="$WATCHDOT_NATIVE_BUILD_DIR/libWatchDotOpus-watchos.a"
 else
  native_rtc="$WATCHDOT_NATIVE_BUILD_DIR/rtc-watchsimulator/libopenclaw_watch_rtc.a"
  native_opus="$WATCHDOT_NATIVE_BUILD_DIR/opus-watchsimulator-arm64/libWatchDotOpus.a"
 fi
 cp "$native_rtc" "$project_root/src/Vendor/OpenClawWatchRTC.xcframework/$slice/libopenclaw_watch_rtc.a"
 cp "$native_opus" "$project_root/src/Vendor/WatchDotOpus.xcframework/$slice/libWatchDotOpus.a"
 cp "$native_root/RTC/include/OpenClawWatchRTC.h" "$project_root/src/Vendor/OpenClawWatchRTC.xcframework/$slice/Headers/OpenClawWatchRTC/OpenClawWatchRTC.h"
 cp "$native_root/Opus/include/WatchDotOpus.h" "$project_root/src/Vendor/WatchDotOpus.xcframework/$slice/Headers/WatchDotOpus/WatchDotOpus.h"
done
printf '%s\n' 'Native device and simulator libraries rebuilt.'
