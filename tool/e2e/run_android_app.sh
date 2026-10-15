#!/usr/bin/env bash
# End-to-end for the **Android app**: the real GUI, on a device or emulator,
# signing in against the real API and bringing up a real WireGuard tunnel —
# stock, obfuscated (AWG) and stream — through the app's in-process VpnService.
# See tool/e2e/README.md for what the run covers.
#
# Unlike the desktop runners there is no privileged helper to install: Android
# runs the data plane in-process, and the app is unprivileged like any other.
# The one piece of device state this needs is the device's VPN consent, which
# the runner grants up front (see below) so no system dialog can stall an
# automated connect.
#
# Credentials come from the environment or the gitignored `.env.e2e`, never a
# flag: the process list is world-readable and a password there outlives the
# run. They reach the app as `--dart-define-from-file`, because an on-device run
# cannot read the host environment (see integration_test/app_e2e.dart). The API
# URL comes from `.env` the same way, exactly as `make run` passes it.
set -euo pipefail

[[ $EUID -ne 0 ]] \
  || { printf 'e2e: run_android_app.sh must NOT run as root (flutter refuses root); run it as the normal user\n' >&2; exit 1; }
[[ -n ${SUDO_UID:-} ]] \
  && { printf 'e2e: run_android_app.sh must NOT run under sudo; run it as the normal user\n' >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
client_repo="$(cd "$here/../.." && pwd)"

# `flutter build`/`flutter test` locate the project from the working directory,
# so the runner pins it rather than depending on where it was invoked from.
cd "$client_repo"

log() { printf '\n=== %s\n' "$*"; }
die() { printf 'e2e: %s\n' "$*" >&2; exit 1; }

for tool in flutter adb python3; do
  command -v "$tool" >/dev/null || die "$tool is required but not installed"
done

# --- the device --------------------------------------------------------------
# One attached device is the common case (the lab's emulator, local or forwarded
# over TCP). Anything else needs the operator to name the target rather than
# have the runner guess and send the run to the wrong one.
if [[ -n ${BOLTMESH_E2E_ANDROID_SERIAL:-} ]]; then
  serial="$BOLTMESH_E2E_ANDROID_SERIAL"
elif [[ -n ${ANDROID_SERIAL:-} ]]; then
  serial="$ANDROID_SERIAL"
else
  mapfile -t devices < <(adb devices | awk '$2 == "device" { print $1 }')
  [[ ${#devices[@]} -ge 1 ]] \
    || die "no adb device: attach an emulator or device, or set BOLTMESH_E2E_ANDROID_SERIAL"
  [[ ${#devices[@]} -eq 1 ]] \
    || die "more than one adb device attached (${devices[*]}); set BOLTMESH_E2E_ANDROID_SERIAL to pick one"
  serial="${devices[0]}"
fi
adb -s "$serial" get-state >/dev/null 2>&1 \
  || die "$serial is not a live adb device"

# --- credentials -------------------------------------------------------------
# The environment wins when it carries both halves; anything missing falls back
# to the lab's .env.e2e, so a bare `tool/e2e/run_android_app.sh` needs no export
# first. The file is parsed with sed and never sourced — reading it executes
# nothing — and unquote hands over the raw secret even when it carries quotes or
# shell metacharacters.
api_user="${BOLTMESH_E2E_API_USER:-}"
api_password="${BOLTMESH_E2E_API_PASSWORD:-}"
CREDS_FILE="${BOLTMESH_E2E_CREDS_FILE:-$client_repo/.env.e2e}"
env_file="${ENV_FILE:-$client_repo/.env}"

unquote() {
  local value=$1 first=${1:0:1} last=${1: -1}
  if [[ ${#value} -ge 2 && ( $first == '"' || $first == "'" ) && $first == "$last" ]]; then
    value=${value:1:${#value}-2}
  fi
  printf '%s' "$value"
}

if [[ -z $api_user || -z $api_password ]]; then
  [[ -f $CREDS_FILE ]] \
    || die "BOLTMESH_E2E_API_USER/BOLTMESH_E2E_API_PASSWORD are not both set and there is no $CREDS_FILE (override with BOLTMESH_E2E_CREDS_FILE)"
  [[ -n $api_user ]] \
    || api_user=$(unquote "$(sed -n 's/^BOLTMESH_E2E_API_USER=//p' "$CREDS_FILE" | tail -1)")
  [[ -n $api_password ]] \
    || api_password=$(unquote "$(sed -n 's/^BOLTMESH_E2E_API_PASSWORD=//p' "$CREDS_FILE" | tail -1)")
  [[ -n $api_user && -n $api_password ]] \
    || die "$CREDS_FILE must set BOLTMESH_E2E_API_USER and BOLTMESH_E2E_API_PASSWORD"
fi
[[ -f $env_file ]] \
  || die "no $env_file: copy .env.example to .env, or point ENV_FILE at one"

app_id=com.boltmesh.boltmesh

# --- VPN consent and a fresh store -------------------------------------------
# Two pieces of device state the run depends on, set before the app connects:
#
#   * consent. `VpnService.prepare` pops a system dialog the first time an app
#     wants a TUN, and nothing inside the test can tap it — the run would hang
#     on the dialog and read as a dead transport. Granting the appop up front
#     makes `prepare` return null, so the dialog never appears. (`pm clear`
#     below does not reset the appop, but the grant is idempotent anyway.)
#   * a fresh store. The app persists its session and device identity in the
#     Android keystore/SharedPreferences, so a leftover session would skip the
#     sign-in form and reuse the previous device row. Clearing app data makes
#     each run start from the form. `BOLTMESH_E2E_KEEP_SESSION=1` keeps the
#     store instead, to exercise the restore path.
#
# The app has to exist before the appop can name it, so a debug APK is installed
# first. `flutter test` below rebuilds and reinstalls the same package; a
# reinstall preserves both the appop and the cleared data. That install only has
# to put *an* APK of the package on the device, so the last build is reused when
# it is there and rebuilt only when it is not -- one Gradle invocation per run
# instead of two. The binary that actually runs the tests is still built fresh
# from source by `flutter test`, which carries the app's `--dart-define`s that
# this plain build does not.
apk="$client_repo/build/app/outputs/flutter-apk/app-debug.apk"
if [[ -f $apk ]]; then
  log "reusing the existing debug APK for the pre-install on $serial"
else
  log "building and installing a debug APK on $serial"
  flutter build apk --debug
  [[ -f $apk ]] || die "expected $apk after the build"
fi
adb -s "$serial" install -r -t "$apk" >/dev/null

log "granting VPN consent for $app_id"
adb -s "$serial" shell cmd appops set "$app_id" ACTIVATE_VPN allow

if [[ ${BOLTMESH_E2E_KEEP_SESSION:-0} == 1 ]]; then
  log "keeping the app's stored session (BOLTMESH_E2E_KEEP_SESSION=1)"
else
  log "clearing app data for a fresh sign-in"
  adb -s "$serial" shell pm clear "$app_id" >/dev/null
fi

# --- clear the account's devices ---------------------------------------------
# A run that fails part-way leaves its device row behind even though the
# interface is gone, and the subscription caps how many can be active. The next
# run then cannot provision, and it reports a device limit the run reporting it
# never caused. Resetting the count up front keeps a red run from poisoning the
# next one. Same contract as the desktop runners:
# `BOLTMESH_E2E_KEEP_DEVICES=1` skips it and `BOLTMESH_E2E_DRY_RUN=1` lists
# without deleting.
if [[ ${BOLTMESH_E2E_KEEP_DEVICES:-0} == 1 ]]; then
  log "keeping existing devices (BOLTMESH_E2E_KEEP_DEVICES=1)"
else
  log "clearing the account's devices"
  clear_args=(--clear-devices --api-base "$(sed -n 's/^API_BASE_URL=//p' "$env_file" | tail -1)")
  if [[ ${BOLTMESH_E2E_DRY_RUN:-0} == 1 ]]; then
    clear_args+=(--dry-run)
  fi
  python3 "$here/client.py" "${clear_args[@]}" \
    --api-user "$api_user" --api-password "$api_password"
fi

# --- run the app -------------------------------------------------------------
# A leftover tunnel here is in-process and dies with the app, so it cannot
# follow the device the way a desktop helper's full-tunnel follows the box. Say
# so anyway if a tun is somehow still up once the test process is gone.
cleanup() {
  local status=$?
  set +e
  if adb -s "$serial" shell ip addr show 2>/dev/null | grep -qE '\btun[0-9]'; then
    printf '\ne2e: a tunnel is still up on %s; stop it with:\n  adb -s %s shell am force-stop %s\n' \
      "$serial" "$serial" "$app_id" >&2
  fi
  exit "$status"
}
trap cleanup EXIT

log "running the Android app end to end on $serial"
echo "  credentials: $api_user (password from the environment)"
echo "  defines:     $env_file + $CREDS_FILE"

flutter test integration_test/app_e2e.dart \
  -d "$serial" \
  --reporter expanded \
  --dart-define-from-file="$env_file" \
  --dart-define-from-file="$CREDS_FILE"

log "e2e PASSED"
