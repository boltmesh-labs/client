#!/usr/bin/env bash
# Native-platform contract checks the Dart and Go unit suites cannot cover:
# the systemd units and staged Linux package payload, the Android manifest the
# background tunnel depends on, and the Windows helper channel wiring.
#
# Runs on Linux (CI's validate-native job). The Windows named-pipe transport
# itself is compiled and exercised by the validate-windows job.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

ok() { printf 'ok    %s\n' "$*"; }
bad() {
  printf 'FAIL  %s\n' "$*" >&2
  fail=1
}

# --- Linux: the systemd units parse ---------------------------------------
if command -v systemd-analyze >/dev/null 2>&1; then
  # The one expected diagnostic is the missing ExecStart target: the deb/rpm
  # postinstall installs it, so it is absent on the runner. Everything else
  # (unknown directives, bad references, syntax) must be clean.
  verify_out="$(systemd-analyze verify \
    boltmeshd/deploy/boltmeshd.service \
    boltmeshd/deploy/boltmeshd.socket 2>&1 || true)"
  unexpected="$(printf '%s\n' "$verify_out" | grep -v -E 'is not executable|^$' || true)"
  if [[ -n "$unexpected" ]]; then
    bad "systemd unit verification"
    printf '%s\n' "$unexpected" >&2
  else
    ok "systemd units verify"
  fi
else
  printf 'skip  systemd-analyze unavailable\n'
fi

# --- Linux: the helper stages into a bundle and runs ----------------------
if command -v go >/dev/null 2>&1; then
  bundle="$(mktemp -d)"
  trap 'rm -rf "$bundle"' EXIT
  if BUILD_OUTPUT_DIRECTORY="$bundle" bash boltmeshd/packaging/stage.sh >/dev/null 2>&1; then
    for artifact in boltmeshd boltmeshd.service boltmeshd.socket 99-boltmesh-unmanaged.conf; do
      [[ -f "$bundle/boltmeshd/$artifact" ]] || bad "staged payload is missing $artifact"
    done
    if [[ -x "$bundle/boltmeshd/boltmeshd" ]] &&
      "$bundle/boltmeshd/boltmeshd" --version >/dev/null 2>&1; then
      ok "boltmeshd stages into the bundle and reports a version"
    else
      bad "staged boltmeshd binary is not executable"
    fi
  else
    bad "boltmeshd/packaging/stage.sh failed"
  fi
else
  printf 'skip  go unavailable\n'
fi

# --- Android: the manifest contract the background tunnel relies on -------
manifest="android/app/src/main/AndroidManifest.xml"
require_manifest() {
  if grep -qE "$1" "$manifest"; then
    ok "Android manifest: $2"
  else
    bad "Android manifest is missing $2"
  fi
}
require_manifest 'android.permission.INTERNET' 'INTERNET'
require_manifest 'android.permission.ACCESS_NETWORK_STATE' 'ACCESS_NETWORK_STATE'
require_manifest 'android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE' \
  'FOREGROUND_SERVICE_CONNECTED_DEVICE'
require_manifest "com\\.wireguard\\.android\\.backend\\.GoBackend\\\$VpnService" 'VpnService entry'
require_manifest 'BIND_VPN_SERVICE' 'BIND_VPN_SERVICE permission'
require_manifest 'orban\.group\.wireguard_flutter\.VpnForegroundService' \
  'plugin foreground service'
require_manifest 'android:stopWithTask="false"' \
  'stopWithTask=false (cached engine survives a task swipe)'

service_patch='android/patches/wireguard_flutter_plus/VpnForegroundService.kt'
service_on_create="$(
  sed -n '/override fun onCreate()/,/override fun onStartCommand/p' "$service_patch"
)"
if grep -qF 'return START_NOT_STICKY' "$service_patch" &&
  grep -qF 'if (intent?.action == ACTION_START)' "$service_patch" &&
  grep -qF 'setContentIntent(contentIntent)' "$service_patch" &&
  grep -qF 'getLaunchIntentForPackage(packageName)' "$service_patch" &&
  grep -qF 'MAIN_ACTIVITY_CLASS' "$service_patch" &&
  ! grep -qF 'startForeground(' <<< "$service_on_create" &&
  grep -qF 'prepareWireguardAndroid' android/build.gradle.kts; then
  ok 'Android WireGuard service is non-sticky and launches the app from its notification'
else
  bad 'Android WireGuard service patch is missing its non-sticky/launch contract'
fi
# The plugin only receives custom-scheme callbacks through its own
# CallbackActivity. Check the activity and its scoped URI together; checking
# for a scheme anywhere in the manifest would also pass when it is registered
# on MainActivity, which does not complete the plugin request.
callback_activity="$(
  sed -n '/android:name="com\.linusu\.flutter_web_auth_2\.CallbackActivity"/,/<\/activity>/p' \
    "$manifest"
)"
if [[ -n "$callback_activity" ]] &&
  grep -qF 'android:exported="true"' <<< "$callback_activity" &&
  grep -qF 'android:taskAffinity=""' <<< "$callback_activity" &&
  grep -qF 'android:name="android.intent.action.VIEW"' <<< "$callback_activity" &&
  grep -qF 'android:name="android.intent.category.DEFAULT"' <<< "$callback_activity" &&
  grep -qF 'android:name="android.intent.category.BROWSABLE"' <<< "$callback_activity" &&
  grep -qF 'android:scheme="boltmesh"' <<< "$callback_activity" &&
  grep -qF 'android:host="auth"' <<< "$callback_activity" &&
  grep -qF 'android:path="/callback"' <<< "$callback_activity"; then
  ok "Android manifest: OAuth CallbackActivity is exported and scoped to boltmesh://auth/callback"
else
  bad "Android manifest is missing the exported, scoped OAuth CallbackActivity"
fi

main_activity="$(
  sed -n '/android:name="\.MainActivity"/,/<\/activity>/p' "$manifest"
)"
if [[ -n "$main_activity" ]] && ! grep -qF 'android:scheme="boltmesh"' <<< "$main_activity"; then
  ok "Android manifest: MainActivity does not own the OAuth callback"
else
  bad "Android manifest registers an OAuth scheme on MainActivity"
fi

# --- Windows: the helper channel is wired end to end ----------------------
channel='com.boltmesh/helper'
if grep -qF "$channel" windows/runner/helper_pipe.cpp; then
  ok "Windows helper channel is registered"
else
  bad "windows/runner/helper_pipe.cpp does not register $channel"
fi
if grep -qF "MethodChannel('$channel')" lib/features/vpn/data/helper_socket_io.dart; then
  ok "Dart helper channel matches the native one"
else
  bad "NativePipeHelperSocket does not use $channel"
fi
if grep -qF 'helper_pipe_io.cpp' windows/runner/CMakeLists.txt; then
  ok "Windows helper transport is compiled"
else
  bad "helper_pipe_io.cpp is not built by windows/runner/CMakeLists.txt"
fi

# --- Windows: the app ships x64-only --------------------------------------
# The wireguard_flutter_plus plugin bundles amd64 tunnel/wireguard DLLs only,
# so the staging hook must refuse an arm64 bundle and the installer must stay
# pinned to x64 (which still installs on Windows on ARM via emulation).
stage_ps1='windows/packaging/stage_boltmeshd.ps1'
if grep -qF 'Windows arm64 is not supported' "$stage_ps1" &&
  grep -qF "GOARCH = 'amd64'" "$stage_ps1"; then
  ok "Windows staging rejects non-x64 bundles and pins GOARCH=amd64"
else
  bad "windows/packaging/stage_boltmeshd.ps1 no longer enforces the x64-only contract"
fi
inno_config='windows/packaging/exe/make_config.yaml'
if grep -qE '^[[:space:]]*architectures_allowed:[[:space:]]*x64compatible[[:space:]]*$' "$inno_config" &&
  grep -qE '^[[:space:]]*architectures_install_in_64bit_mode:[[:space:]]*x64compatible[[:space:]]*$' "$inno_config"; then
  ok "Windows installer pins x64compatible"
else
  bad "windows/packaging/exe/make_config.yaml is not pinned to x64compatible"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "native platform contract checks failed" >&2
  exit 1
fi
echo "native platform contract checks passed"
