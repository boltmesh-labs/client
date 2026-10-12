#!/usr/bin/env bash
# Builds the Android debug helpers (ptrace_catch, xver) with the NDK.
#
#   tool/android-debug/build.sh [abi]      # abi defaults to x86_64
#
# Output: build/android-debug/<abi>/{ptrace_catch,xver} (gitignored), ready to
# `adb push` to /data/local/tmp. See README.md for the run.
set -euo pipefail

abi="${1:-x86_64}"
case "$abi" in
  x86_64) triple=x86_64-linux-android ;;
  arm64-v8a) triple=aarch64-linux-android ;;
  armeabi-v7a) triple=armv7a-linux-androideabi ;;
  x86) triple=i686-linux-android ;;
  *)
    printf 'unsupported ABI: %s\n' "$abi" >&2
    exit 1
    ;;
esac
# 30 is the app's minSdk; every modern NDK ships a matching clang wrapper.
api=30

ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z $ndk ]]; then
  for candidate in "$HOME/Android/Sdk/ndk/"*; do
    [[ -d $candidate ]] && ndk=$candidate
  done
fi
[[ -n $ndk && -d $ndk ]] || {
  printf 'set ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) to the NDK\n' >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$repo/build/android-debug/$abi"
mkdir -p "$out"

cc="$(find "$ndk/toolchains/llvm/prebuilt" -maxdepth 3 -name "${triple}${api}-clang" | head -1)"
[[ -x $cc ]] || {
  printf 'no %s under %s\n' "${triple}${api}-clang" "$ndk" >&2
  exit 1
}

"$cc" -O2 -Wall -o "$out/xver" "$here/xver.c" -ldl
"$cc" -O2 -Wall -o "$out/ptrace_catch" "$here/ptrace_catch.c"
printf 'built: %s\n' "$out/xver" "$out/ptrace_catch"
