#!/usr/bin/env bash
# Native-platform contract checks the Dart and Go unit suites cannot cover:
# the systemd units and staged Linux package payload, the Android manifest the
# background tunnel depends on, and the Windows helper channel wiring.
#
# Runs on Linux (CI's validate-native job). The Windows named-pipe transport is
# cross-compiled here with mingw-w64 but not executed (it drives overlapped
# named-pipe I/O, which Wine does not emulate faithfully); the validate-windows
# job builds and runs it.
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

# wg-quick enables policy routing for a full-tunnel AllowedIPs list and writes
# src_valid_mark, but the helper must not be granted that write: the unit keeps
# ProtectKernelTunables, so /proc/sys is read-only in the helper's namespace,
# and systemd >= 259 fails the unit with status=226/NAMESPACE when a
# ReadWritePaths= entry points inside that hierarchy. The tunable is therefore
# set host-wide by the packaged sysctl.d drop-in, which also makes wg-quick
# skip its own write. Assert both halves: no /proc/sys exception in the unit,
# and the drop-in that replaces it is still shipped.
read_write_paths="$(sed -n 's/^ReadWritePaths=//p' boltmeshd/deploy/boltmeshd.service)"
proc_sys_writable=0
for path in $read_write_paths; do
  case "${path#-}" in
    /proc/sys | /proc/sys/*) proc_sys_writable=1 ;;
  esac
done
src_valid_mark_conf=boltmeshd/deploy/80-boltmesh-src-valid-mark.conf
if grep -qE '^ProtectKernelTunables=yes$' boltmeshd/deploy/boltmeshd.service &&
  [[ "$proc_sys_writable" -eq 0 ]] &&
  grep -qx 'net.ipv4.conf.all.src_valid_mark = 1' "$src_valid_mark_conf"; then
  ok 'Linux full-tunnel sets src_valid_mark host-wide, not via a /proc/sys exception'
else
  bad 'Linux full-tunnel cannot write wg-quick src_valid_mark safely'
fi

# Print one YAML scriptlet list from a packaging config, one entry per block.
# Grepping the raw file is not enough: fastforge merges these lists into single
# %post and %postun sections, so the same command can legitimately appear in
# both, and a raw `grep -n | cut -d: -f1` then yields two line numbers and
# breaks any ordering arithmetic.
yaml_scriptlets() {
  python3 - "$1" "$2" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
for item in yaml.safe_load(open(sys.argv[1])).get(sys.argv[2]) or []:
    print(item)
PY
}

# Both packages have to ship that drop-in, or the helper loses full-tunnel.
# Check each file separately: grep -q across several files succeeds on any one
# match, which would let a package silently drop the drop-in.
src_valid_mark_staged=0
if grep -q '80-boltmesh-src-valid-mark.conf' boltmeshd/packaging/stage.sh; then
  src_valid_mark_staged=1
fi
for config in linux/packaging/rpm/make_config.yaml linux/packaging/deb/make_config.yaml; do
  grep -q 'sysctl.d/80-boltmesh-src-valid-mark.conf' "$config" || src_valid_mark_staged=0
done
if [[ "$src_valid_mark_staged" -eq 1 ]]; then
  ok 'the deb and rpm packages stage and install the src_valid_mark drop-in'
else
  bad 'a Linux package does not install the src_valid_mark drop-in'
fi

# Fastforge reads postinstall_scripts/postuninstall_scripts as a list of
# strings. A plain YAML scalar holding ": " (any printf message) parses as a
# map instead and aborts the maker with a cast error, so every entry has to
# stay a string. Block scalars keep their text verbatim, which is what the
# enroll-user and teardown entries already rely on.
for config in linux/packaging/rpm/make_config.yaml linux/packaging/deb/make_config.yaml; do
  non_string="$(python3 - "$config" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
for key in ("postinstall_scripts", "postuninstall_scripts"):
    for item in yaml.safe_load(open(sys.argv[1])).get(key) or []:
        if not isinstance(item, str):
            print(f"{sys.argv[1]}: {key} entry is {type(item).__name__}, not a string")
PY
)"
  if [[ -z "$non_string" ]]; then
    ok "$config scriptlets are all strings"
  else
    bad "$non_string"
  fi
done

# procps' `sysctl --load` reads only /etc/sysctl.conf and /etc/sysctl.d, so it
# exits 0 while silently skipping a /usr/lib/sysctl.d drop-in. Applying through
# systemd-sysctl (or a direct sysctl -w) is what actually reaches the file.
for config in linux/packaging/rpm/make_config.yaml linux/packaging/deb/make_config.yaml; do
  # Strip comment lines first: the entry above explains this trap by name.
  if grep -v '^[[:space:]]*#' "$config" | grep -q 'sysctl --load'; then
    bad "$config applies sysctl with procps 'sysctl --load', which skips /usr/lib/sysctl.d"
  else
    ok "$config applies the src_valid_mark drop-in through systemd-sysctl"
  fi
done

# Unit teardown, shared by the upgrade and uninstall scriptlets. Two mistakes
# here are silent: a socket unit has no MainPID and prints an empty value, so a
# bare `= 0` test failed for boltmeshd.socket and aborted %postun on every
# uninstall; and `systemctl stop` on a unit that is not installed returns
# non-zero, which under `set -e` aborted %post on the first upgrade from a
# build that shipped no units. Require the LoadState probe and the empty-tolerant
# MainPID test wherever a scriptlet stops units, and require the absent-helper
# guard before the teardown that runs ahead of the removals.
for config in linux/packaging/rpm/make_config.yaml linux/packaging/deb/make_config.yaml; do
  teardown_ok=1
  postun="$(yaml_scriptlets "$config" postuninstall_scripts)"
  # Only the rpm %post quiesces units, and only on upgrade ($1 -gt 1); dpkg has
  # no equivalent hook here. Key off that guard, not off the unit name, which
  # also appears in the deb's plain install lines.
  post="$(yaml_scriptlets "$config" postinstall_scripts)"
  if grep -q -- '-gt 1' <<<"$post"; then
    grep -q 'LoadState' <<<"$post" || teardown_ok=0
    # shellcheck disable=SC2016  # literal match against the emitted script
    grep -q '\[ -z "\$main_pid" \] || \[ "\$main_pid" = 0 \]' <<<"$post" || teardown_ok=0
  fi
  grep -q 'LoadState' <<<"$postun" || teardown_ok=0
  # shellcheck disable=SC2016  # literal match against the emitted script
  grep -q '\[ -z "\$main_pid" \] || \[ "\$main_pid" = 0 \]' <<<"$postun" || teardown_ok=0
  # An absent helper must not abort the removals that follow it.
  grep -q '\[ -x /usr/libexec/boltmesh/boltmeshd \]' <<<"$postun" || teardown_ok=0
  # The teardown must also be skipped unless this is a final erase. rpm passes
  # %postun the number of remaining copies: 0 on a final erase, but 1 both on a
  # fresh install and when an upgrade retires the old version. dpkg passes
  # postrm the action word. Tearing down on an upgrade deleted the helper and
  # units the incoming %post had just staged, leaving no helper at all.
  if [[ "$config" == *rpm* ]]; then
    # shellcheck disable=SC2016  # literal match against the emitted script
    grep -qF '[ "${1:-0}" -ne 0 ]' <<<"$postun" || teardown_ok=0
  else
    grep -qF 'remove | purge' <<<"$postun" || teardown_ok=0
  fi
  if [[ "$teardown_ok" -eq 1 ]]; then
    ok "$config unit teardown tolerates not-found units and an empty MainPID"
  else
    bad "$config unit teardown can abort %post/%postun on a stopped or absent unit"
  fi
done

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
  # Scope to the uninstall scriptlet: the rpm %post also stops units on upgrade,
  # so grepping the whole file matches stop_unit twice and the line arithmetic
  # below breaks.
  postun_text="$(yaml_scriptlets "$package_config" postuninstall_scripts)"
  reload_line="$(grep -n 'systemctl daemon-reload' <<<"$postun_text" | sed -n '1p' | cut -d: -f1)"
  service_line="$(grep -n 'stop_unit boltmeshd.service' <<<"$postun_text" | sed -n '1p' | cut -d: -f1)"
  socket_line="$(grep -n 'stop_unit boltmeshd.socket' <<<"$postun_text" | sed -n '1p' | cut -d: -f1)"
  cleanup_line="$(grep -n -- '--cleanup --config-dir=/run/boltmesh --interface=boltmesh0' <<<"$postun_text" | sed -n '1p' | cut -d: -f1)"
  if [[ -n "$reload_line" && -n "$service_line" && -n "$socket_line" && -n "$cleanup_line" &&
    "$reload_line" -lt "$service_line" && "$service_line" -lt "$socket_line" && "$socket_line" -lt "$cleanup_line" ]] &&
    grep -q 'MainPID' <<<"$postun_text" &&
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
# Match the shape of the corrected upgrade block rather than one spelling of it,
# and never let a failed grep abort the run: under `set -e` a missing match used
# to kill this script mid-way and report success for every check after it.
rpm_postinstall_text="$(yaml_scriptlets "$rpm_config" postinstall_scripts)"
line_of() { grep -nF -- "$1" <<<"$2" | sed -n '1p' | cut -d: -f1 || true; }
# shellcheck disable=SC2016  # literal match against the emitted script
rpm_upgrade_guard_line="$(line_of 'if [ "${1:-1}" -gt 1 ]; then' "$rpm_postinstall_text")"
rpm_upgrade_stop_line="$(line_of 'if ! stop_unit boltmeshd.service || ! stop_unit boltmeshd.socket; then' "$rpm_postinstall_text")"
rpm_helper_install_line="$(line_of 'install -Dm755 /usr/share/boltmesh/boltmeshd/boltmeshd ' "$rpm_postinstall_text")"
# A unit that will not stop must still abort the upgrade rather than let the
# payload overwrite a binary the running helper still maps.
rpm_upgrade_fail_closed="$(grep -cF 'exit 1' <<<"$rpm_postinstall_text" || true)"
if [[ -n "$rpm_upgrade_guard_line" && -n "$rpm_upgrade_stop_line" &&
  -n "$rpm_helper_install_line" && -n "$rpm_upgrade_fail_closed" &&
  "$rpm_upgrade_guard_line" -lt "$rpm_upgrade_stop_line" &&
  "$rpm_upgrade_stop_line" -lt "$rpm_helper_install_line" ]]; then
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
  # NetworkManager's reload is optional by contract. The unit-stop suppression
  # inside the upgrade teardown is deliberate too: `systemctl stop` reports
  # non-zero for a unit that is already gone or was never installed, and the
  # LoadState/ActiveState/MainPID assertions that follow are the real gate, so
  # nothing is masked.
  unit_stop_literal="$(printf 'systemctl stop "$%s"' unit)"
  unexpected_suppression="$(
    printf '%s\n' "$postinstall_section" |
      grep -F '|| true' |
      grep -vF 'nmcli general reload conf' |
      grep -vF "$unit_stop_literal" || true
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
# The Flutter-free test must be EXCLUDE_FROM_ALL. Flutter builds the INSTALL
# target and the fastforge exe packager copies the whole runner output directory
# into the installer's [Files] wildcard, so an ALL target would be built next to
# boltmesh.exe and shipped. The validate-windows job builds it by name instead.
if grep -qF 'add_executable(helper_pipe_io_tests EXCLUDE_FROM_ALL' \
  windows/runner/CMakeLists.txt; then
  ok "Windows helper test is excluded from the packaged bundle"
else
  bad "helper_pipe_io_tests is an ALL target and would ship in the Windows installer"
fi
# The pipe name is globally predictable, so the transport must authenticate the
# server as the SCM-reported boltmeshd service process before it sends a
# request (which may carry the WireGuard private key).
if grep -qF 'GetNamedPipeServerProcessId' windows/runner/helper_pipe_io.cpp &&
  grep -qF 'QueryServiceStatusEx' windows/runner/helper_pipe_io.cpp &&
  grep -qF 'kHelperServiceName' windows/runner/helper_pipe_io.cpp; then
  ok "Windows helper transport authenticates the boltmeshd service process"
else
  bad "Windows helper transport can send a request to a pre-created pipe"
fi

# --- Windows: cross-compile the C++ transport test -------------------------
# The named-pipe transport is Windows-only C++ that only the Flutter-gated
# validate-windows job otherwise compiles. Cross-compile the standalone,
# Flutter-free test with mingw-w64 so a Windows-only C++ break is caught here
# too. It is not executed here: the test drives overlapped named-pipe I/O,
# which Wine emulates incompletely (the process can hang), so behavioural
# coverage stays on Windows.
if command -v x86_64-w64-mingw32-g++ >/dev/null 2>&1; then
  runner_build="$(mktemp -d)"
  # -Wall/-Wextra/-Werror mirrors windows/CMakeLists.txt /W4 /WX, so a warning
  # the Windows build would reject fails the Linux job as well.
  if x86_64-w64-mingw32-g++ -std=c++17 -Wall -Wextra -Werror -DNOMINMAX \
    -DBOLTMESH_HELPER_PIPE_TEST -I windows/runner \
    windows/runner/tests/helper_pipe_io_test.cpp \
    windows/runner/helper_pipe_io.cpp \
    -o "$runner_build/helper_pipe_io_tests.exe" -lkernel32 -ladvapi32; then
    ok 'Windows runner C++ test cross-compiles with mingw-w64'
  else
    bad 'Windows runner C++ test does not cross-compile with mingw-w64'
  fi
  rm -rf "$runner_build"
else
  printf 'skip  x86_64-w64-mingw32-g++ unavailable\n'
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
# go build runs after Push-Location $helperDir, so the output path must be the
# resolved absolute one. A relative -BuildDir (the hook's own .EXAMPLE) wrote the
# helper into boltmeshd/<BuildDir>, still printed success, and left the
# installer shipping without the privileged helper. The Windows verify script
# exercises the hook end to end; this keeps the regression visible on Linux.
if grep -qF "Join-Path \$buildPath 'boltmeshd.exe'" "$stage_ps1" &&
  ! grep -qF "Join-Path \$BuildDir 'boltmeshd.exe'" "$stage_ps1"; then
  ok "Windows staging writes the helper to the resolved bundle path"
else
  bad "windows/packaging/stage_boltmeshd.ps1 stages the helper through a relative path"
fi
# A staged helper is what a user runs `boltmeshd -version` on, so the go build
# itself must pass the metadata the Makefile injects. Checking the go build line
# rather than the whole file matters: an earlier version computed $ldflags and
# then still called go build with a bare '-s -w', so the helper shipped as
# `dev (unknown, built unknown)` while the assignment sat unused in the file.
if grep -F "go build -trimpath -ldflags \$ldflags" "$stage_ps1" >/dev/null &&
  grep -qF -- '-X main.Version=' "$stage_ps1"; then
  ok "Windows staging stamps the helper's version metadata"
else
  bad "windows/packaging/stage_boltmeshd.ps1 ships a helper with no version metadata"
fi
# `go build -o` cannot replace a running image. When the helper service runs from
# the bundle, go leaves boltmeshd.exe~ behind, exits 0, and the bundle keeps the
# OLD helper while the hook claims success -- so the installer ships a stale
# privileged binary. Stage to a scratch name, move it in, and clear the
# leftovers; a mere Test-Path cannot catch this.
if grep -qF 'boltmeshd.staging.exe' "$stage_ps1" &&
  grep -qF "Filter 'boltmeshd.exe~'" "$stage_ps1" &&
  grep -qF "Move-Item -LiteralPath \$staged" "$stage_ps1"; then
  ok "Windows staging cannot ship a helper locked by a running service"
else
  bad "windows/packaging/stage_boltmeshd.ps1 can stage a stale helper when its service is running"
fi
# The package is Inno Setup 7. fastforge's default ISCC path is hardcoded to
# 'Inno Setup 6', so the release job has to both install 7 and export
# INNO_SETUP_PATH, or packing fails on a bare `iscc` that is not on PATH.
release_yml='.github/workflows/release.yml'
if grep -qF 'INNO_SETUP_PATH=C:\Program Files\Inno Setup 7' "$release_yml" &&
  ! grep -qF 'choco install innosetup' "$release_yml"; then
  ok "Windows release installs Inno Setup 7 and points fastforge at it"
else
  bad "the Windows release job does not install Inno Setup 7 via INNO_SETUP_PATH"
fi
# Inno 7 builds a 32-bit Setup by default even from the 64-bit compiler. The
# payload is x64-only, so ask for the 64-bit Setup explicitly rather than
# relying on the edition default.
if grep -qE '^[[:space:]]*SetupArchitecture=x64[[:space:]]*$' windows/packaging/exe/boltmesh.iss; then
  ok "Windows installer builds a 64-bit Setup"
else
  bad "windows/packaging/exe/boltmesh.iss does not set SetupArchitecture=x64"
fi
# ISPP reads any line whose first non-blank character is '[' as a section tag,
# including inside [Code]. A wrapped Pascal argument list like
#     Log(Format('... %d.',
#       [ResultCode]));
# therefore fails to compile with "Invalid section tag" on both Inno 6 and 7.
# Nothing caught it: build-windows only runs on a release tag, so this template
# had never been compiled. Keep such continuations on one line.
if grep -qE '^[[:space:]]+\[[A-Za-z]' windows/packaging/exe/boltmesh.iss; then
  bad "boltmesh.iss has an indented line starting with '[' that ISPP reads as a section tag"
else
  ok "Windows installer has no ISPP-confusable section tags"
fi
# [Code] must open with a declaration. Pascal Scripting reads a leading comment
# as the start of the program body and fails with "'BEGIN' expected" pointing at
# that comment, which reads like a line-ending problem, not a syntax one.
iss_first_code_line="$(
  awk '/^\[Code\][[:space:]]*$/ { seen = 1; next } seen && NF { print; exit }' \
    windows/packaging/exe/boltmesh.iss
)"
# Inside [Code] the comments must not use ';'. Pascal Scripting fails the whole
# compile with "'BEGIN' expected" pointing at the comment line, whether the
# comment is before, between or after declarations, and the message names the
# comment rather than the cause. '//', '{ }' and '(* *)' all compile.
iss_code_semicolon_comments="$(
  awk '/^\[Code\][[:space:]]*$/ { seen = 1; next } seen && /^[[:space:]]*;/ { print NR }' \
    windows/packaging/exe/boltmesh.iss | paste -sd, -
)"
if [[ -z "$iss_first_code_line" ]]; then
  bad "boltmesh.iss has no [Code] body"
elif [[ -n "$iss_code_semicolon_comments" ]]; then
  bad "boltmesh.iss uses ';' comments inside [Code] (line(s) $iss_code_semicolon_comments); use // instead"
else
  ok "Windows installer [Code] avoids ';' comments and opens with a declaration"
fi
inno_config='windows/packaging/exe/make_config.yaml'
if grep -qE '^[[:space:]]*architectures_allowed:[[:space:]]*x64compatible[[:space:]]*$' "$inno_config" &&
  grep -qE '^[[:space:]]*architectures_install_in_64bit_mode:[[:space:]]*x64compatible[[:space:]]*$' "$inno_config"; then
  ok "Windows installer pins x64compatible"
else
  bad "windows/packaging/exe/make_config.yaml is not pinned to x64compatible"
fi

# The installer names the app exe in its shortcuts and post-install launch.
# Without an explicit executable_name the packager picks the first .exe it
# enumerates from the bundle, which also contains boltmeshd.exe and the
# plugin-bundled wireguard_svc.exe, so enumeration order could launch the
# helper or service instead of the GUI.
if grep -qE '^[[:space:]]*executable_name:[[:space:]]*boltmesh\.exe[[:space:]]*$' "$inno_config"; then
  ok "Windows installer pins the app executable name"
else
  bad "windows/packaging/exe/make_config.yaml does not pin executable_name: boltmesh.exe"
fi

# The pre-packing hook must sign the whole staged bundle, not just the app and
# helper: the bundle also carries the plugin-bundled wireguard_svc.exe that the
# LocalSystem boltmeshd helper launches, so it must not ship unsigned. sign.ps1
# recurses a directory for *.exe, so passing the bundle directory covers every
# executable the installer places in {app}.
distribute_options='distribute_options.yaml'
if grep -qF "sign.ps1 -Path \"\$BUILD_OUTPUT_DIRECTORY\"" "$distribute_options"; then
  ok "Windows pre-packing hook signs every bundled executable"
else
  bad "Windows pre-packing hook leaves a bundled executable unsigned"
fi

# The LocalSystem helper and tunnel services load their binaries from {app}, so
# a user-writable install directory is a SYSTEM code-execution path. The
# directory page must stay hidden and the [Code] guard must reject a /DIR
# override that lands outside the protected Program Files tree.
inno_iss='windows/packaging/exe/boltmesh.iss'
if grep -qE '^[[:space:]]*DisableDirPage=yes[[:space:]]*$' "$inno_iss" &&
  grep -qF "ExpandConstant('{autopf64}')" "$inno_iss" &&
  grep -qF 'not InstallDirIsProtected' "$inno_iss"; then
  ok "Windows installer pins the protected Program Files directory"
else
  bad "windows/packaging/exe/boltmesh.iss allows a user-writable install directory"
fi

# Inno only logs a [Run] program's exit code, so installing the helper there
# could not fail the install. The helper install must run from [Code] (before
# the postinstall app launch), suppress that launch when it fails, and report a
# nonzero setup exit code.
if grep -qF "Exec(HelperPath, '-install'" "$inno_iss" &&
  grep -qF 'ResultCode <> 0' "$inno_iss" &&
  grep -qF 'Check: HelperInstalled' "$inno_iss" &&
  grep -qF 'if HelperInstallFailed then' "$inno_iss" &&
  ! grep -qF 'Parameters: "-install"' "$inno_iss"; then
  ok "Windows installer installs the helper fail-closed before launching the app"
else
  bad "windows/packaging/exe/boltmesh.iss can install and launch a bundle with a failed helper"
fi

# The helper binary owns the service and tunnel teardown, so an uninstall must
# not complete when the helper is missing and a privileged service or the
# private-key config is still present. It probes for them with sc.exe and aborts
# (fail closed) instead of silently skipping cleanup.
if grep -qF 'function ServiceExists' "$inno_iss" &&
  grep -qF "ServiceExists('boltmeshd')" "$inno_iss" &&
  grep -qF "ServiceExists('boltmesh0')" "$inno_iss" &&
  grep -qF '{commonappdata}\BoltMesh\boltmesh0.conf' "$inno_iss" &&
  grep -qF 'Reinstall BoltMesh' "$inno_iss"; then
  ok "Windows uninstaller fails closed when the helper is missing"
else
  bad "windows/packaging/exe/boltmesh.iss can silently leave services behind"
fi

# Apple Network Extension entitlements. The extension *target* is created in
# Xcode (it cannot be committed), but the entitlements the app target carries
# can drift silently: a missing `networkextension` or App Group entry only
# shows up as an opaque failure inside the Packet Tunnel extension on a
# developer's Mac. Assert them here so the drift fails on Linux CI instead.
#
# The App Group must also match the one the app hands to the plugin; the Dart
# side reads the same value from the VPN_APP_GROUP define, so both are
# checked against the group declared in the entitlements.
apple_entitlements=(
  ios/Runner/Runner.entitlements
  macos/Runner/DebugProfile.entitlements
  macos/Runner/Release.entitlements
)
for f in "${apple_entitlements[@]}"; do
  if [[ ! -f "$f" ]]; then
    bad "$f is missing"
    continue
  fi
  if ! grep -q 'com.apple.developer.networking.networkextension' "$f" ||
    ! grep -q 'packet-tunnel-provider' "$f"; then
    bad "$f does not declare the packet-tunnel-provider capability"
  elif ! grep -q 'com.apple.security.application-groups' "$f"; then
    bad "$f declares no App Group (the extension reads the wgQuick config from it)"
  else
    ok "Apple entitlements declare the tunnel capability and App Group ($f)"
  fi
done

# The adapter hands the plugin this App Group on Apple. A define that drifted
# from the entitlements file would build cleanly and fail only at connect.
apple_app_group=$(grep -ho 'group\.[A-Za-z0-9._-]*' \
  macos/Runner/Release.entitlements | head -1)
if [[ -z "$apple_app_group" ]]; then
  bad "no App Group id found in macos/Runner/Release.entitlements"
elif grep -qF "$apple_app_group" SETUP.md; then
  ok "the entitlements App Group is documented for the VPN_APP_GROUP define"
else
  bad "the entitlements App Group ($apple_app_group) is not documented for VPN_APP_GROUP"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "native platform contract checks failed" >&2
  exit 1
fi
echo "native platform contract checks passed"
