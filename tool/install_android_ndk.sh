#!/usr/bin/env bash
# Installs the Android NDK that the JNI build and Flutter's Gradle plugin are
# both pinned to, and points ANDROID_NDK_HOME at it for the rest of the job.
#
# It is a script rather than a step in each workflow because `ci.yml` and
# `release.yml` need the same pinned NDK, and installing it means working around
# two `sdkmanager` behaviours:
#
#   * it verifies nothing about the archive it downloads, so a truncated
#     transfer fails as "Error on ZipFile unknown archive" at whatever
#     percentage the connection died;
#   * it keeps that partial archive, so a rerun fails identically instead of
#     recovering.
#
# Roughly one Android job in four died on this before the retry existed.
# Keeping the workaround in one place is what stops the two workflows drifting
# apart on it.
#
# The pinned version is read from tool/build_awg_android.py -- the repository's
# copy of the version Flutter's Gradle plugin sets
# (FlutterExtension.ndkVersion) and what android/app/build.gradle.kts hands the
# JNI build -- so the pin lives in one place rather than in each workflow.
# Exporting it to $GITHUB_ENV matters because `build_awg_android.py --check`
# resolves ANDROID_NDK_HOME *before* the pinned copy under $ANDROID_HOME: without
# it, the check vets and lints against whatever NDK the runner image installed
# by default (27.3.x on ubuntu-24.04) rather than the one that ships.
#
# Usage: tool/install_android_ndk.sh   (idempotent; needs ANDROID_HOME)
set -euo pipefail

cd "$(dirname "$0")/.."

ndk_version="$(python3 -c '
import sys
sys.path.insert(0, "tool")
from build_awg_android import NDK_VERSION
print(NDK_VERSION)
')"

: "${ANDROID_HOME:?ANDROID_HOME must point at the Android SDK}"
sdkmanager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
ndk_dir="$ANDROID_HOME/ndk/$ndk_version"
max_attempts=3

if [ -d "$ndk_dir" ]; then
  echo "Android NDK $ndk_version is already installed"
else
  attempt=1
  while true; do
    if "$sdkmanager" "ndk;$ndk_version"; then
      break
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "::error::Could not install Android NDK $ndk_version after $max_attempts attempts"
      exit 1
    fi
    echo "::warning::Android NDK install attempt $attempt failed; clearing the partial download and retrying"
    rm -rf "$ndk_dir" "$ANDROID_HOME/.temp" "$ANDROID_HOME/temp"
    sleep $((attempt * 15))
    attempt=$((attempt + 1))
  done
fi

# Later steps in the jobs that call this need the pinned NDK, not the image's
# default; outside CI there is no such file to write and the path is echoed.
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "ANDROID_NDK_HOME=$ndk_dir" >>"$GITHUB_ENV"
fi
echo "Using Android NDK $ndk_version at $ndk_dir"
