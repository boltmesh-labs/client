#!/usr/bin/env bash
# End-to-end for the **Linux desktop app**: the real GUI, in a real window,
# signing in against the real API and connecting through the real privileged
# boltmeshd. See README.md ("The app, not just the daemon") for what this adds
# over tool/e2e/run.sh, which stops at the helper.
#
# Everything below exists to make that possible on a headless lab box. None of
# it is part of the app:
#
#   Xvfb            a display, because XDG_SESSION_TYPE=tty has none
#   --no-enable-impeller
#                   Mesa's llvmpipe is a software rasterizer, and Impeller's
#                   OpenGLES backend misbehaves against it (SETUP.md §3)
#   a private keyring
#                   the app persists its session through libsecret, which
#                   needs an unlocked collection; isolating XDG_DATA_HOME keeps
#                   a lab run off the operator's real login keyring
#
# Credentials come from the environment, never a flag: the process list is
# world-readable and a password there outlives the run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
client_repo="$(cd "$here/../.." && pwd)"

api_user="${BOLTMESH_E2E_API_USER:-}"
api_password="${BOLTMESH_E2E_API_PASSWORD:-}"

# .env supplies API_BASE_URL (and optionally WEBSITE_URL / TLS_PIN_SPKI_SHA256)
# as compile-time --dart-defines, the same way `make run` does. A run pointed at
# a different backend is ENV_FILE=staging.env, not an edit to the file.
env_file="${ENV_FILE:-$client_repo/.env}"
workdir="${BOLTMESH_E2E_WORK_DIR:-/tmp/boltmesh-linux-app-e2e}"
# The keyring's collection password is a lab detail; it guards an empty
# scratch keyring, never anything real. Fixed rather than random so a rerun can
# reuse the stored session, which is what exercises the restore path.
keyring_password="${BOLTMESH_E2E_KEYRING_PASSWORD:-boltmesh-e2e}"
display_num="${BOLTMESH_E2E_DISPLAY:-:99}"

log() { printf '\n=== %s\n' "$*"; }
die() { printf 'e2e: %s\n' "$*" >&2; exit 1; }

[[ -n $api_user && -n $api_password ]] \
  || die "BOLTMESH_E2E_API_USER and BOLTMESH_E2E_API_PASSWORD must be set in the environment"
[[ -f $env_file ]] \
  || die "no $env_file: copy .env.example to .env, or point ENV_FILE at one"

required=(flutter ip ping go)
# Optional, and only for the screenshots the test takes when it is told where to
# put them: its absence costs you the pictures, not the run.
command -v import >/dev/null || printf 'e2e: note: ImageMagick import not found; screenshots will be skipped\n' >&2
for tool in "${required[@]}"; do
  command -v "$tool" >/dev/null || die "$tool is required but not installed"
done

# --- build and install the helper --------------------------------------------
# The app talks to the *running* systemd helper, so a stale install tests stale
# protocol code. Build from source and install it here so the run always
# exercises the current tree.
log "building boltmeshd from source"
(cd "$client_repo/boltmeshd" && CGO_ENABLED=0 go build -trimpath -o "$workdir/boltmeshd" ./cmd/boltmeshd)

log "installing boltmeshd (needs sudo)"
sudo install -Dm755 "$workdir/boltmeshd" /usr/libexec/boltmesh/boltmeshd
sudo systemctl restart boltmeshd.service
# Wait for the socket to come back up
for _ in $(seq 1 40); do
  [[ -S /run/boltmesh/boltmeshd.sock ]] && break
  sleep 0.25
done
[[ -S /run/boltmesh/boltmeshd.sock ]] \
  || die "boltmeshd socket did not come up after restart"
id -nG | tr ' ' '\n' | grep -qx boltmesh \
  || die "this user is not in the boltmesh group: run boltmesh-enroll-user (SETUP.md §4)"

rm -rf "$workdir"
mkdir -p "$workdir/xdg" "$workdir/shots"
shot_dir="$workdir/shots"

xvfb_pid=""
cleanup() {
  local status=$?
  set +e
  # A leftover full-tunnel would follow this box, not the run, so say so loudly
  # rather than leaving a silent default route into a tunnel nobody is watching.
  if ip link show boltmesh0 >/dev/null 2>&1; then
    printf '\ne2e: WARNING boltmesh0 is still up; tear it down with:\n  sudo wg-quick down /run/boltmesh/wgboltmesh0.conf || sudo ip link del boltmesh0\n' >&2
  fi
  [[ -n $xvfb_pid ]] && kill "$xvfb_pid" 2>/dev/null
  if [[ $status -eq 0 ]]; then
    rm -rf "$workdir/xdg"
  else
    printf '\ne2e: run failed; artifacts kept in %s\n' "$workdir" >&2
  fi
  exit $status
}
trap cleanup EXIT

# --- a display --------------------------------------------------------------

display_socket="/tmp/.X11-unix/X${display_num#:}"

log "starting a virtual display on $display_num"
# The X socket is the readiness signal, not `xdpyinfo`: that comes from
# xdpyinfo's package (xorg-x11-utils), which a minimal image need not have, and
# its absence must not read as "no display".
if [[ ! -S $display_socket ]]; then
  Xvfb "$display_num" -screen 0 1600x1000x24 -nolisten tcp >"$workdir/xvfb.log" 2>&1 &
  xvfb_pid=$!
  for _ in $(seq 1 40); do
    [[ -S $display_socket ]] && break
    sleep 0.25
  done
  [[ -S $display_socket ]] || die "Xvfb did not come up (see $workdir/xvfb.log)"
fi

# --- an unlocked keyring, private to this run -------------------------------

log "unlocking a scratch keyring (isolated from the operator's login keyring)"
# The daemon is one per user session, so --replace takes over from whatever
# desktop session daemon exists. That is fine here: XDG_DATA_HOME points the
# collection at this run's scratch directory, so nothing the operator's own
# keyring holds is unlocked, read or rewritten. --unlock reads the collection
# password from stdin, which is why the printf is piped rather than passed.
printf '%s' "$keyring_password" \
  | XDG_DATA_HOME="$workdir/xdg" gnome-keyring-daemon --unlock --replace \
    >"$workdir/keyring.log" 2>&1 || true
for _ in $(seq 1 20); do
  if printf 'probe' | XDG_DATA_HOME="$workdir/xdg" secret-tool store \
      --label='boltmesh e2e probe' service boltmesh-e2e-probe key probe >/dev/null 2>&1; then
    probe_ok=1
    break
  fi
  sleep 0.25
done
# Probed with a real write on purpose: a lookup for an item that does not exist
# exits non-zero even against a perfectly good collection, so it cannot tell
# unlocked from locked — and "libsecret would fail every secure-storage write"
# is exactly the failure that would otherwise surface as a baffling login error.
[[ ${probe_ok:-0} == 1 ]] \
  || die "the scratch keyring stayed locked; see $workdir/keyring.log"
XDG_DATA_HOME="$workdir/xdg" secret-tool clear service boltmesh-e2e-probe >/dev/null 2>&1 || true

# --- run the app ------------------------------------------------------------

log "running the Linux app end to end"
echo "  credentials: $api_user (password from the environment)"
echo "  defines:     $env_file"
echo "  screenshots: $shot_dir"

DISPLAY="$display_num" \
XDG_DATA_HOME="$workdir/xdg" \
BOLTMESH_E2E_API_USER="$api_user" \
BOLTMESH_E2E_API_PASSWORD="$api_password" \
BOLTMESH_E2E_SHOT_DIR="$shot_dir" \
  flutter test integration_test/linux_app_e2e.dart \
    -d linux \
    --no-enable-impeller \
    --dart-define-from-file="$env_file"

log "e2e PASSED — screenshots in $shot_dir"
