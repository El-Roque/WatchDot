#!/usr/bin/env bash
set -euo pipefail
opus_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
opus_sdk="${1:?SDK required}"
opus_arch="${2:?Architecture required}"
opus_source="$opus_root/vendor/opus-1.6.1"
# Autoconf rejects spaces in srcdir, including a normal iCloud checkout path.
opus_source_alias="$(mktemp -d /tmp/watchdot-opus.XXXXXX)"
trap 'rm -f "$opus_source_alias/source"; rmdir "$opus_source_alias"' EXIT
ln -s "$opus_source" "$opus_source_alias/source"
opus_source="$opus_source_alias/source"
opus_output="${WATCHDOT_NATIVE_BUILD_DIR:?Set WATCHDOT_NATIVE_BUILD_DIR}/opus-$opus_sdk-$opus_arch"
opus_sdkroot="$(xcrun --sdk "$opus_sdk" --show-sdk-path)"
opus_clang="$(xcrun --sdk "$opus_sdk" --find clang)"
case "$opus_sdk/$opus_arch" in
  watchos/arm64_32) opus_target=arm64_32-apple-watchos11.0; opus_host=arm-apple-darwin ;;
  watchos/arm64) opus_target=arm64-apple-watchos26.0; opus_host=aarch64-apple-darwin ;;
  watchsimulator/arm64) opus_target=arm64-apple-watchos11.0-simulator; opus_host=aarch64-apple-darwin ;;
  macosx/arm64) opus_target=arm64-apple-macos15.0; opus_host=aarch64-apple-darwin ;;
  *) echo 'Unsupported Opus build target' >&2; exit 2 ;;
esac
opus_flags="-Os -fPIC -isysroot $opus_sdkroot -target $opus_target -ffile-prefix-map=$HOME=/home/developer -ffile-prefix-map=$opus_source=/WatchDot/Native/Opus/vendor/opus-1.6.1"
mkdir -p "$opus_output"
cd "$opus_output"
lt_cv_sys_max_cmd_len=262144 CC="$opus_clang" CFLAGS="$opus_flags" LDFLAGS="$opus_flags" \
 "$opus_source/configure" --srcdir="$opus_source" --host="$opus_host" --disable-shared --enable-static \
 --disable-extra-programs --disable-doc --disable-asm --disable-intrinsics --disable-rtcd \
 --disable-dred --disable-deep-plc --disable-osce --disable-qext --disable-maintainer-mode
make -j "${WATCHDOT_BUILD_JOBS:-2}"
"$opus_clang" -target "$opus_target" -isysroot "$opus_sdkroot" -Os -fPIC "-ffile-prefix-map=$HOME=/home/developer" \
 -I "$opus_root/include" -I "$opus_source/include" -c "$opus_root/src/WatchDotOpus.c" -o WatchDotOpus.o
xcrun libtool -static -o libWatchDotOpus.a .libs/libopus.a WatchDotOpus.o
