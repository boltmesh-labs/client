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
  # The expected diagnostics are the missing ExecStart/ExecStopPost targets:
  # the deb/rpm postinstall installs the binary, so it is absent on the runner.
  # Everything else (unknown directives, bad references, syntax) must be clean.
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

# wg-quick enables policy routing for a full-tunnel AllowedIPs list by writing
# src_valid_mark. Preserve ProtectKernelTunables for every other kernel setting,
# but exempt exactly that file; otherwise strict mode cannot establish its
# default route and wg-quick up aborts.
read_write_paths="$(sed -n 's/^ReadWritePaths=//p' boltmeshd/deploy/boltmeshd.service)"
src_valid_mark_writable=0
proc_sys_fully_writable=0
for path in $read_write_paths; do
  case "${path#-}" in
    /proc/sys/net/ipv4/conf/all/src_valid_mark) src_valid_mark_writable=1 ;;
    /proc/sys | /proc/sys/*) proc_sys_fully_writable=1 ;;
  esac
done
if grep -qE '^ProtectKernelTunables=yes$' boltmeshd/deploy/boltmeshd.service &&
  [[ "$src_valid_mark_writable" -eq 1 && "$proc_sys_fully_writable" -eq 0 ]]; then
  ok 'Linux full-tunnel keeps a narrow src_valid_mark exception'
else
  bad 'Linux full-tunnel cannot write wg-quick src_valid_mark safely'
fi

# The daemon's signal path and the unit-level fallback must both tear down the
# tunnel, and the service (not the socket) must own the runtime directory that
# contains the wg-quick config during shutdown. The unit deliberately uses
# systemd's synchronous SIGTERM/KillMode=mixed path rather than an asynchronous
# ExecStop signal wrapper.
if grep -qE '^KillSignal=SIGTERM$' boltmeshd/deploy/boltmeshd.service &&
  grep -qE '^KillMode=mixed$' boltmeshd/deploy/boltmeshd.service &&
  grep -qE '^ExecStopPost=.*--cleanup' boltmeshd/deploy/boltmeshd.service &&
  ! grep -qE '^ExecStop=' boltmeshd/deploy/boltmeshd.service &&
  grep -qE '^RuntimeDirectory=boltmesh$' boltmeshd/deploy/boltmeshd.service &&
  grep -qE '^RuntimeDirectoryPreserve=yes$' boltmeshd/deploy/boltmeshd.service &&
  grep -qE '^DirectoryMode=0755$' boltmeshd/deploy/boltmeshd.socket &&
  ! grep -qE '^RuntimeDirectory=' boltmeshd/deploy/boltmeshd.socket; then
  ok 'Linux shutdown owns the tunnel and preserves its config for cleanup'
else
  bad 'Linux shutdown cleanup contract is incomplete'
fi

if grep -qE '^SocketUser=root$' boltmeshd/deploy/boltmeshd.socket &&
  grep -qE '^SocketGroup=boltmesh$' boltmeshd/deploy/boltmeshd.socket &&
  grep -qE '^SocketMode=0660$' boltmeshd/deploy/boltmeshd.socket; then
  ok 'Linux helper socket remains root:boltmesh 0660'
else
  bad 'Linux helper socket access contract is incomplete'
fi

for package_config in linux/packaging/deb/make_config.yaml linux/packaging/rpm/make_config.yaml; do
  reload_line="$(grep -n 'systemctl daemon-reload' "$package_config" | sed -n '2p' | cut -d: -f1)"
  service_line="$(grep -n 'stop_unit boltmeshd.service' "$package_config" | cut -d: -f1)"
  socket_line="$(grep -n 'stop_unit boltmeshd.socket' "$package_config" | cut -d: -f1)"
  cleanup_line="$(grep -n -- '--cleanup --config-dir=/run/boltmesh --interface=boltmesh0' "$package_config" | cut -d: -f1)"
  if [[ -n "$reload_line" && -n "$service_line" && -n "$socket_line" && -n "$cleanup_line" &&
    "$reload_line" -lt "$service_line" && "$service_line" -lt "$socket_line" && "$socket_line" -lt "$cleanup_line" ]] &&
    grep -q 'MainPID' "$package_config" &&
    ! grep -q 'rm -rf /run/boltmesh' "$package_config"; then
    ok "Linux package cleanup ordering: $package_config"
  else
    bad "Linux package cleanup ordering is incomplete: $package_config"
  fi
done

# wg-quick always configures DNS here, and strict full-tunnel mode also
# installs firewall rules. Those tools are only recommendations (or undeclared)
# in the base packages, so make the complete command surface a hard dependency.
prerequisites_ok=1
deb_config=linux/packaging/deb/make_config.yaml
rpm_config=linux/packaging/rpm/make_config.yaml
for dependency in iproute2 nftables resolvconf; do
  grep -qE "^  - ${dependency}$" "$deb_config" || prerequisites_ok=0
done
for dependency in iproute nftables systemd-resolved; do
  grep -qE "^  - ${dependency}$" "$rpm_config" || prerequisites_ok=0
done
if [[ "$prerequisites_ok" -eq 1 ]]; then
  ok 'Linux packages install the complete wg-quick command set'
else
  bad 'Linux package dependencies omit a wg-quick runtime command'
fi

# Fastforge puts these scripts in RPM's %post. Because the helper and units
# are not package-owned, an upgrade must stop the old service before replacing
# its binary, verify no process remains, and only then install the new payload.
rpm_postinstall_section="$(
  sed -n '/^postinstall_scripts:/,/^postuninstall_scripts:/p' "$rpm_config"
)"
rpm_upgrade_guard="if [ \"\${1:-1}\" -gt 1 ]; then"
rpm_upgrade_stop='systemctl stop boltmeshd.service boltmeshd.socket'
rpm_upgrade_pid="main_pid=\"\$(systemctl show --property=MainPID --value boltmeshd.service)\""
rpm_upgrade_pid_guard="if [ \"\$main_pid\" != 0 ]; then"
rpm_upgrade_guard_line="$(printf '%s\n' "$rpm_postinstall_section" | grep -nF "$rpm_upgrade_guard" | cut -d: -f1)"
rpm_upgrade_stop_line="$(printf '%s\n' "$rpm_postinstall_section" | grep -nF "$rpm_upgrade_stop" | cut -d: -f1)"
rpm_upgrade_pid_line="$(printf '%s\n' "$rpm_postinstall_section" | grep -nF "$rpm_upgrade_pid" | cut -d: -f1)"
rpm_helper_install_line="$(printf '%s\n' "$rpm_postinstall_section" | grep -nF '  - install -Dm755 /usr/share/boltmesh/boltmeshd/boltmeshd' | cut -d: -f1)"
if [[ -n "$rpm_upgrade_guard_line" && -n "$rpm_upgrade_stop_line" &&
  -n "$rpm_upgrade_pid_line" && -n "$rpm_helper_install_line" &&
  "$rpm_upgrade_guard_line" -lt "$rpm_upgrade_stop_line" &&
  "$rpm_upgrade_stop_line" -lt "$rpm_upgrade_pid_line" &&
  "$rpm_upgrade_pid_line" -lt "$rpm_helper_install_line" ]] &&
  printf '%s\n' "$rpm_postinstall_section" | grep -qF "$rpm_upgrade_pid_guard"; then
  ok 'RPM upgrades stop and verify the old privileged helper before replacement'
else
  bad 'RPM upgrade can replace the helper binary while the old process is active'
fi

# The package must not infer authorization solely from SUDO_USER or discard a
# failed group update.  The staged command handles polkit metadata, logind
# discovery, and an explicit fallback for root-shell/headless installs.
enrollment_ok=1
enrollment_script=boltmeshd/packaging/enroll-user.sh
[[ -x "$enrollment_script" ]] || enrollment_ok=0
sh -n "$enrollment_script" || enrollment_ok=0
grep -qF 'PKEXEC_UID' "$enrollment_script" || enrollment_ok=0
grep -qF 'SUDO_USER' "$enrollment_script" || enrollment_ok=0
grep -qF 'loginctl' "$enrollment_script" || enrollment_ok=0
grep -qF 'session_remote' "$enrollment_script" || enrollment_ok=0
grep -qF 'session_class' "$enrollment_script" || enrollment_ok=0
grep -qF 'x11|wayland' "$enrollment_script" || enrollment_ok=0
# loginctl emits a formatted table; keep whitespace-aware parsing in the helper.
grep -qF 'read -r session_id session_uid' "$enrollment_script" || enrollment_ok=0
! grep -qF 'session_line%% *' "$enrollment_script" || enrollment_ok=0
grep -qF 'usermod -aG' "$enrollment_script" || enrollment_ok=0
for package_config in linux/packaging/deb/make_config.yaml linux/packaging/rpm/make_config.yaml; do
  enroll_line="$(grep -nF '/usr/libexec/boltmesh/boltmesh-enroll-user --auto' "$package_config" | cut -d: -f1)"
  socket_enable_line="$(grep -nF 'systemctl enable --now boltmeshd.socket' "$package_config" | cut -d: -f1)"
  grep -qF 'rm -f /usr/libexec/boltmesh/boltmesh-enroll-user' "$package_config" || enrollment_ok=0
  if [[ "$package_config" == *'/deb/'* ]]; then
    grep -qE '^  - passwd$' "$package_config" || enrollment_ok=0
    grep -qE '^  - systemd$' "$package_config" || enrollment_ok=0
  else
    grep -qE '^  - shadow-utils$' "$package_config" || enrollment_ok=0
    grep -qE '^  - systemd$' "$package_config" || enrollment_ok=0
  fi
  if [[ -z "$enroll_line" || -z "$socket_enable_line" || "$enroll_line" -ge "$socket_enable_line" ]]; then
    enrollment_ok=0
  elif grep -qE '^[[:space:]]*[^#].*(SUDO_USER|usermod)' "$package_config" ||
    grep -qF 'boltmesh-enroll-user --auto || true' "$package_config"; then
    enrollment_ok=0
  fi
done
if [[ "$enrollment_ok" -eq 1 ]]; then
  ok 'Linux desktop enrollment is independent of the package manager caller'
else
  bad 'Linux desktop enrollment contract is incomplete'
fi

# Fastforge concatenates postinstall entries into one shell script, and the
# Debian packager appends `exit 0`. The first custom entry must therefore
# propagate the prepended status and enable fail-fast mode before any helper
# setup runs. Only NetworkManager's optional configuration reload may suppress
# an error; a package with a failed install, enrollment, or socket setup must
# not be reported as configured.
postinstall_ok=1
for package_config in linux/packaging/deb/make_config.yaml linux/packaging/rpm/make_config.yaml; do
  postinstall_section="$(
    sed -n '/^postinstall_scripts:/,/^postuninstall_scripts:/p' "$package_config"
  )"
  prior_status_line="$(printf '%s\n' "$postinstall_section" | grep -nF 'postinstall_status=$?' | cut -d: -f1)"
  fail_fast_line="$(printf '%s\n' "$postinstall_section" | grep -nF '    set -e' | cut -d: -f1)"
  helper_install_line="$(printf '%s\n' "$postinstall_section" | grep -nF '  - install -Dm755' | sed -n '1p' | cut -d: -f1)"
  daemon_reload_line="$(printf '%s\n' "$postinstall_section" | grep -nF '  - systemctl daemon-reload' | cut -d: -f1)"
  socket_enable_line="$(printf '%s\n' "$postinstall_section" | grep -nF '  - systemctl enable --now boltmeshd.socket' | cut -d: -f1)"
  nmcli_line="$(printf '%s\n' "$postinstall_section" | grep -nF '  - nmcli general reload conf >/dev/null 2>&1 || true' | cut -d: -f1)"
  unexpected_suppression="$(
    printf '%s\n' "$postinstall_section" |
      grep -F '|| true' |
      grep -vF 'nmcli general reload conf' || true
  )"

  if [[ -z "$prior_status_line" || -z "$fail_fast_line" || -z "$helper_install_line" ||
    -z "$daemon_reload_line" || -z "$socket_enable_line" || -z "$nmcli_line" ||
    -n "$unexpected_suppression" ||
    "$prior_status_line" -ge "$fail_fast_line" || "$fail_fast_line" -ge "$helper_install_line" ||
    "$helper_install_line" -ge "$daemon_reload_line" || "$daemon_reload_line" -ge "$socket_enable_line" ||
    "$socket_enable_line" -ge "$nmcli_line" ]]; then
    postinstall_ok=0
  fi
done
if [[ "$postinstall_ok" -eq 1 ]]; then
  ok 'Linux package postinstall fails fast after critical helper setup errors'
else
  bad 'Linux package postinstall can mask a critical helper setup error'
fi

# --- Linux: native title and desktop window identity -----------------------
runner=linux/runner/my_application.cc
if grep -qF 'gtk_header_bar_set_title(header_bar, "boltmesh")' "$runner" ||
  grep -qF 'gtk_window_set_title(window, "boltmesh")' "$runner"; then
  bad 'Linux runner still hard-codes the native GTK title'
else
  ok 'Linux runner leaves the native title to Flutter'
fi

for package_config in linux/packaging/deb/make_config.yaml linux/packaging/rpm/make_config.yaml; do
  if grep -qE '^[[:space:]]*startup_wm_class:[[:space:]]*com\.boltmesh\.boltmesh[[:space:]]*$' "$package_config"; then
    ok "Linux desktop entry declares the GTK WM_CLASS: $package_config"
  else
    bad "Linux desktop entry omits the xprop-confirmed WM_CLASS: $package_config"
  fi
done
rpm_config=linux/packaging/rpm/make_config.yaml
if grep -qF "printf '\\n%s\\n' 'StartupWMClass=com.boltmesh.boltmesh'" "$rpm_config"; then
  ok 'RPM postinstall adds StartupWMClass to its generated desktop entry'
else
  bad 'RPM postinstall does not add StartupWMClass to its generated desktop entry'
fi

# --- Linux: the helper stages into a bundle and runs ----------------------
if command -v go >/dev/null 2>&1; then
  bundle="$(mktemp -d)"
  trap 'rm -rf "$bundle"' EXIT
  if BUILD_OUTPUT_DIRECTORY="$bundle" bash boltmeshd/packaging/stage.sh >/dev/null 2>&1; then
    for artifact in boltmeshd boltmeshd.service boltmeshd.socket 99-boltmesh-unmanaged.conf boltmesh-enroll-user; do
      [[ -f "$bundle/boltmeshd/$artifact" ]] || bad "staged payload is missing $artifact"
    done
    [[ -x "$bundle/boltmeshd/boltmesh-enroll-user" ]] ||
      bad "staged desktop enrollment command is not executable"
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
