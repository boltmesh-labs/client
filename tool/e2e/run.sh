#!/usr/bin/env bash
# End-to-end check for the stream transport: this machine's real boltmeshd, over a
# real WireGuard tunnel, to a real node that is already running.
#
# See README.md for what this does and does not prove. The short version: it rules
# out the failure where both halves pass their own unit tests — against golden
# vectors, a fake kernel, a hand-rolled dial helper — and still do not interoperate.
# It proves nothing about evading a real DPI.
#
# There is no stub and no second helper here. The node is a real deployed node: it
# registers itself, heartbeats, binds its ingress, and reports its own TLS pin,
# and the API only advertises the stream rung to a device once that pin exists. So
# a pass here means the client's bridge and the node's ingress interoperate across
# a real TLS session, over a real tunnel, with the real credentials.
#
# Requires root (wg and wg-quick are privileged).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
client_repo="$(cd "$here/../.." && pwd)"

keep=0
bin_dir=""
region=""
# BOLTMESH_E2E_DEBUG=1 keeps the work directory and logs even when the run fails.
debug_keep="${BOLTMESH_E2E_DEBUG:-0}"
for arg in "$@"; do
  case "$arg" in
    --keep) keep=1 ;;
    --bin-dir=*) bin_dir="${arg#*=}" ;;
    --region=*) region="${arg#*=}" ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# BOLTMESH_E2E_API_USER / BOLTMESH_E2E_API_PASSWORD. Never flags: the process list
# is world-readable, and a password on it outlives the run.
api_user="${BOLTMESH_E2E_API_USER:-}"
api_password="${BOLTMESH_E2E_API_PASSWORD:-}"

client_iface=boltmesh0

workdir="$(mktemp -d /tmp/boltmesh-e2e.XXXXXX)"
client_socket="$workdir/boltmeshd.sock"

log() { printf '\n=== %s\n' "$*"; }
die() { printf 'e2e: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (wg and wg-quick are privileged)"
[[ -n $api_user && -n $api_password ]] \
  || die "BOLTMESH_E2E_API_USER and BOLTMESH_E2E_API_PASSWORD must be set in the environment"

required=(wg wg-quick ip python3)
[[ -z $bin_dir ]] && required+=(go)
for tool in "${required[@]}"; do
  command -v "$tool" >/dev/null || die "$tool is required but not installed"
done

cleanup() {
  local status=$?
  set +e
  # Leave the host as we found it: this runs in the host namespace, so a leftover
  # interface and its routes would follow the box, not the harness.
  python3 "$here/client.py" --socket "$client_socket" --down >/dev/null 2>&1 || true
  if [[ -f $workdir/boltmeshd.pid ]]; then
    kill "$(cat "$workdir/boltmeshd.pid")" 2>/dev/null
  fi
  if [[ $keep -eq 1 && $status -eq 0 ]] || [[ $debug_keep -eq 1 ]]; then
    log "leaving $workdir up for inspection"
    printf '  client.log  up.log  badpsk.log  native.log  client-state.json\n' >&2
  else
    # A failed run keeps its logs: the one file that said why the tunnel never came
    # up is exactly what you want after the fact.
    if [[ $status -eq 0 ]]; then
      rm -rf "$workdir"
    else
      printf '\ne2e: run failed; logs kept in %s\n' "$workdir" >&2
    fi
  fi
  exit $status
}
trap cleanup EXIT

# --- build ----------------------------------------------------------------

if [[ -n $bin_dir ]]; then
  [[ -x "$bin_dir/boltmeshd" ]] || die "--bin-dir given but $bin_dir/boltmeshd is missing"
  cp "$bin_dir/boltmeshd" "$workdir/"
  log "using prebuilt boltmeshd from $bin_dir"
else
  log "building boltmeshd"
  (cd "$client_repo/boltmeshd" && go build -o "$workdir/boltmeshd" ./cmd/boltmeshd)
fi

# --- this run's device identity -------------------------------------------

# The keypair is kept between runs, keyed by region, and reused when it is there.
#
# Reuse is not a shortcut, it is a requirement: the backend stores only the public
# half, and the node's peer table is built from it. A fresh keypair under a reused
# device name would leave the client holding a private key no peer matches, and
# the tunnel would never handshake — which reads as a network problem rather than
# an identity mismatch. The device name is derived from the key, so a new keypair
# is a new device rather than a collision.
#
# Both starts this run makes (up, wrong PSK) read the same file, so they cannot
# disagree about which device they are.
log "preparing this run's device identity"
api_base="$(grep -E '^API_BASE_URL=' "$client_repo/.env" 2>/dev/null | cut -d= -f2- || true)"
[[ -n $api_base ]] || die "could not read API_BASE_URL from $client_repo/.env"
[[ -n $region ]] || die "--region is required: the device is bound to a region and the API picks the node"

# The keypair is kept per-region and reused on later runs.
#
# Where it lands needs care: this script runs under sudo, and sudo resets $HOME to
# root's, so a plain $HOME would silently put the operator's device key in /root —
# unreadable for cleanup and invisible to the person who ran it. SUDO_USER is the
# account that actually invoked the run, so its state directory is the right one,
# and BOLTMESH_E2E_STATE_DIR overrides both for a box that wants it elsewhere.
state_home="${BOLTMESH_E2E_STATE_DIR:-}"
if [[ -z $state_home && -n ${SUDO_USER:-} ]]; then
  caller_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  [[ -n $caller_home ]] && state_home="$caller_home/.local/state"
fi
state_home="${state_home:-${XDG_STATE_HOME:-$HOME/.local/state}}"
keydir="$state_home/boltmesh"
# Created with the caller's ownership: the file is written by root, and a directory
# root owns inside the operator's own state tree cannot be cleaned up by them.
if [[ -n ${SUDO_UID:-} && -n ${SUDO_GID:-} ]]; then
  mkdir -p "$keydir" && chown "$SUDO_UID:$SUDO_GID" "$keydir"
else
  mkdir -p "$keydir"
fi
keyfile="$keydir/e2e-device-$region.json"
umask 077
if [[ -f $keyfile ]]; then
  log "reusing the stored keypair for region $region ($keyfile)"
else
  client_priv="$(wg genkey)"
  client_pub="$(printf '%s' "$client_priv" | wg pubkey)"
  # Named after the key, so two boxes (or two regions) never collide and a rotated
  # key is a new device rather than a device the backend already knows by another
  # identity.
  device_name="e2e-${region}-$(printf '%s' "$client_pub" | cut -c1-12)"
  REGION="$region" API_BASE="$api_base" python3 - "$keyfile" "$client_priv" "$client_pub" "$device_name" <<'PY'
import json, os, sys
path, private, public, name = sys.argv[1:5]
state = {"api_base": os.environ["API_BASE"], "region_id": os.environ["REGION"],
         "device_name": name, "client_private_key": private,
         "client_public_key": public}
with open(path, "w") as handle:
    json.dump(state, handle, indent=2)
os.chmod(path, 0o600)
PY
# Hand it to the account that invoked the run. It is written by root, into that
# account's own state directory, so without this the operator could not delete it
# to start clean — which the identity section of the README tells them to do.
if [[ -n ${SUDO_UID:-} && -n ${SUDO_GID:-} ]]; then
  chown "$SUDO_UID:$SUDO_GID" "$keyfile" 2>/dev/null || true
fi
fi

# Copied into the workdir so the run is self-contained and the logs can be read
# without the caller's home directory.
cp "$keyfile" "$workdir/device.json"

# --- start the daemon -----------------------------------------------------

log "starting boltmeshd on this host"
# SOCKET_GROUP is emptied because the daemon's default group ("boltmesh") is an
# install-time artifact of the packaged deployment and does not exist on a bare
# box. Empty means root-only, which is what a lab run needs.
BOLTMESHD_SOCKET="$client_socket" \
BOLTMESHD_SOCKET_GROUP="" \
BOLTMESHD_CONFIG_DIR="$workdir/wgconf" \
BOLTMESHD_LOG_FILE="" \
  "$workdir/boltmeshd" >"$workdir/client.log" 2>&1 &
echo $! >"$workdir/boltmeshd.pid"
for _ in $(seq 1 40); do
  [[ -S "$client_socket" ]] && break
  sleep 0.25
done
[[ -S "$client_socket" ]] || die "boltmeshd did not create its socket (see $workdir/client.log)"

# Idempotent pre-clean: a previous run's interface would make this one's wg-quick
# fail on the address, which reads as a configuration bug.
python3 "$here/client.py" --socket "$client_socket" --down >/dev/null 2>&1 || true

# --- bring the tunnel up --------------------------------------------------

log "bringing the tunnel up against the running node"
python3 "$here/client.py" \
  --socket "$client_socket" \
  --state "$workdir/device.json" \
  --api-user "$api_user" \
  --api-password "$api_password" \
  --state-out "$workdir/client-state.json" \
  >"$workdir/up.log" 2>&1 || {
    tail -20 "$workdir/up.log" >&2
    die "the client could not bring the tunnel up (see $workdir/up.log)"
  }
cat "$workdir/up.log"

# --- assertions -----------------------------------------------------------

fail=0
note_failure() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

node_tunnel_ip="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["node_tunnel_ip"])' \
  "$workdir/client-state.json")"
# On an obfuscated region the client's interface is a userspace AmneziaWG tun, not
# a kernel WireGuard device, so `wg show` reads nothing and a working tunnel looks
# dead. The daemon's own status is the equivalent view there; on the native path
# the kernel's is the stronger one, so it is kept.
inner_format="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("inner_format","native"))' \
  "$workdir/client-state.json")"
echo "inner format: $inner_format"

daemon_field() {
  python3 "$here/client.py" --socket "$client_socket" --status \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1', 0))"
}
# No netns argument: this runs in the host namespace, because the node it dials is
# on the LAN and a bare namespace cannot reach it.
wg_field() {
  # shellcheck disable=SC2016  # awk program, not shell
  wg show "$1" "$2" 2>/dev/null | awk -v col="$3" '{print $col}' || true
}
client_handshake() {
  if [[ "$inner_format" == "awg" ]]; then daemon_field lastHandshake
  else wg_field "$client_iface" latest-handshakes 2 | head -1; fi
}
client_rx() {
  if [[ "$inner_format" == "awg" ]]; then daemon_field rxBytes
  else wg_field "$client_iface" transfer 2 | head -1; fi
}

log "asserting on the tunnel's view"
# WireGuard only initiates on traffic, so this waits rather than reading once.
handshakes_ok=0
for _ in $(seq 1 30); do
  c_hs="$(client_handshake)"
  if [[ -n "$c_hs" && "$c_hs" != "0" ]]; then
    handshakes_ok=1
    break
  fi
  ping -c1 -W1 "$node_tunnel_ip" >/dev/null 2>&1 || true
  sleep 0.5
done
[[ $handshakes_ok -eq 1 ]] || note_failure "no completed handshake on $client_iface"

# Asserting only on ping would pass with zero real WireGuard traffic, because a
# local address short-circuits routing. The counters are the real evidence.
c_rx="$(client_rx)"
echo "client received: ${c_rx:-0} bytes over WireGuard"
[[ -n "${c_rx:-}" && "$c_rx" != "0" ]] || note_failure "the client received nothing over WireGuard"

log "pinging across the tunnel to the node ($node_tunnel_ip)"
if ping_log="$(ping -c3 -W2 "$node_tunnel_ip" 2>&1)"; then
  echo "$ping_log" | tail -3
else
  echo "$ping_log"
  note_failure "the in-tunnel ping failed"
fi
grep -q "0% packet loss" <<<"$ping_log" || note_failure "the in-tunnel ping lost packets"

log "negative check: a wrong PSK must not authenticate"
# A device presenting the wrong credential must not move a single byte. This is
# what would catch the credential store being keyed on something other than the
# client id, or the key proof being skipped outright — both of which every positive
# check above passes happily.
#
# `up` succeeds regardless: the interface and its route come up locally and the
# kernel knows nothing about a stream credential. So the working tunnel is torn down
# first, making a fresh handshake unambiguous evidence. The PSK is mutated rather
# than the client id, because a bad client id is refused by the lookup (unknown
# device) while a bad PSK is refused by the key proof, which is the part worth
# exercising.
python3 "$here/client.py" --socket "$client_socket" --down >/dev/null 2>&1 || true
sleep 1
bad_psk="$(printf 'A%.0s' $(seq 1 43))="
if python3 "$here/client.py" \
    --socket "$client_socket" \
    --state "$workdir/device.json" \
    --api-user "$api_user" \
    --api-password "$api_password" \
    --force-psk "$bad_psk" \
    --state-out "$workdir/badpsk-state.json" >"$workdir/badpsk.log" 2>&1; then
  for _ in $(seq 1 8); do
    ping -c1 -W1 "$node_tunnel_ip" >/dev/null 2>&1 || true
    sleep 1
  done
  bad_hs="$(client_handshake)"
  bad_rx="$(client_rx)"
  if [[ -n "$bad_hs" && "$bad_hs" != "0" ]] || [[ -n "$bad_rx" && "$bad_rx" != "0" ]]; then
    note_failure "a mutated PSK completed a handshake (hs=${bad_hs:-none} rx=${bad_rx:-0})"
  else
    echo "a mutated PSK produced no handshake and moved no bytes, as it must"
  fi
else
  echo "a mutated PSK was refused before the tunnel came up, as it must:"
  tail -3 "$workdir/badpsk.log" | sed 's/^/    /'
fi

# --- result ---------------------------------------------------------------

if [[ $fail -ne 0 ]]; then
  log "e2e FAILED — logs in $workdir"
  exit 1
fi
log "e2e PASSED — logs in $workdir"
