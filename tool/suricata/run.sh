#!/usr/bin/env bash
# Prove, with Suricata, which BoltMesh transports are visible as WireGuard.
#
# It runs the real Linux desktop app e2e (`tool/e2e/run_linux_app.sh`), which
# walks the transport ladder native -> awg -> stream against a real serving
# node, while Suricata watches the client's egress under the installed
# WireGuard rules. It then decides, from Suricata's own eve log, whether native
# tripped the rules and awg/stream did not.
#
# Suricata needs root (af-packet) and the e2e installs the privileged helper,
# so this script calls `sudo`. Credentials for the API come from the e2e's
# environment file (`.env.e2e` by default), never as a flag.
#
# Everything is parameterised by the environment; the defaults describe the
# lab this was built on. See README.md.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
client_repo="$(cd "$here/../.." && pwd)"

IFACE="${SURICATA_IFACE:-ens160}"
NODE_IP="${SURICATA_NODE_IP:-192.168.1.115}"
NATIVE_PORT="${SURICATA_NATIVE_PORT:-51820}"
AWG_PORT="${SURICATA_AWG_PORT:-51821}"
STREAM_PORT="${SURICATA_STREAM_PORT:-443}"
CONTROL_PORT="${SURICATA_CONTROL_PORT:-59999}"
CONFIG="${SURICATA_CONFIG:-/etc/suricata/suricata.yaml}"
KEEP="${SURICATA_KEEP:-0}"
SKIP_E2E="${SURICATA_SKIP_E2E:-0}"
CREDS_FILE="${BOLTMESH_E2E_CREDS_FILE:-$client_repo/.env.e2e}"
workdir="${SURICATA_LOG_DIR:-/tmp/opencode/suricata-$(date +%Y%m%d-%H%M%S)}"

log() { printf '\n=== %s\n' "$*"; }
die() { printf 'suricata-harness: %s\n' "$*" >&2; exit 1; }

# A .env file may quote a value that carries shell metacharacters; hand the
# daemon the raw secret, not the quotes.
unquote() {
  local value=$1 first=${1:0:1} last=${1: -1}
  if [[ ${#value} -ge 2 && ( $first == '"' || $first == "'" ) && $first == "$last" ]]; then
    value=${value:1:${#value}-2}
  fi
  printf '%s' "$value"
}

suricata_pid=""
tcpdump_pid=""
cleanup() {
  local status=$?
  set +e
  if [[ -n $tcpdump_pid ]]; then
    sudo kill -INT "$tcpdump_pid" 2>/dev/null || true
  fi
  if [[ -n $suricata_pid ]] && sudo kill -0 "$suricata_pid" 2>/dev/null; then
    log "stopping Suricata (cleanup)"
    sudo kill -TERM "$suricata_pid" 2>/dev/null || true
  fi
  if [[ $status -eq 0 && $KEEP != 1 ]]; then
    : # artifacts are worth keeping even on success; nothing to remove here
  fi
  exit "$status"
}
trap cleanup EXIT

for tool in suricata tcpdump python3; do
  command -v "$tool" >/dev/null || die "$tool is required but not installed"
done
# /etc/suricata is 0750 (root:suricata), so this needs root to even stat.
sudo test -f "$CONFIG" || die "no Suricata config at $CONFIG (override with SURICATA_CONFIG)"

mkdir -p "$workdir/pcap"
pcap_file="$workdir/pcap/$IFACE.pcap"
extra_rules="$workdir/extra.rules"

# --- build the extra ruleset: our controls, filled in for this run -----------

log "building the control ruleset"
sed -e "s/@NODE_IP@/$NODE_IP/g" \
    -e "s/@AWG_PORT@/$AWG_PORT/g" \
    -e "s/@STREAM_PORT@/$STREAM_PORT/g" \
    "$here/rules/controls.rules" >"$extra_rules"
if [[ -n ${SURICATA_AWG_H1:-} ]]; then
  # Optional targeted-detector control: only meaningful once the node's h1
  # magic is known out of band, which is exactly the caveat this demonstrates.
  printf 'alert udp any any -> %s %s (msg:"Adversarial: AWG known h1 magic"; content:"|%s|"; sid:9900006; rev:1;)\n' \
    "$NODE_IP" "$AWG_PORT" "$SURICATA_AWG_H1" >>"$extra_rules"
fi

# --- validate the configuration before touching the live interface ----------

log "validating the Suricata configuration"
# The redirect is performed by this (unprivileged) shell on purpose, so the log
# is user-readable without the chown the artifacts get at the end.
# shellcheck disable=SC2024
sudo suricata -T -c "$CONFIG" -s "$extra_rules" -l "$workdir" >"$workdir/suricata-validate.log" 2>&1 \
  || die "Suricata rejected the configuration; see $workdir/suricata-validate.log"

# --- start capture -----------------------------------------------------------

log "starting Suricata on $IFACE (logs: $workdir)"
# shellcheck disable=SC2024
sudo suricata -c "$CONFIG" -s "$extra_rules" --af-packet="$IFACE" \
  -l "$workdir" --pidfile "$workdir/suricata.pid" \
  >"$workdir/suricata-stdout.log" 2>&1 &
suricata_pid=$!

for _ in $(seq 1 60); do
  if [[ -s $workdir/eve.json && -f $workdir/suricata.pid ]] && sudo kill -0 "$suricata_pid" 2>/dev/null; then
    break
  fi
  sleep 0.5
done
sudo kill -0 "$suricata_pid" 2>/dev/null \
  || die "Suricata did not come up; see $workdir/suricata-stdout.log"

log "capturing packets on $IFACE (pcap: $pcap_file)"
# shellcheck disable=SC2024
sudo tcpdump -i "$IFACE" -w "$pcap_file" -U -s 0 "host $NODE_IP" \
  >"$workdir/tcpdump.log" 2>&1 &
tcpdump_pid=$!
sleep 1

# --- positive control: prove the engine and rules are live -------------------

log "sending the positive control to $NODE_IP:$CONTROL_PORT"
python3 - "$NODE_IP" "$CONTROL_PORT" <<'PY'
import socket
import sys

ip, port = sys.argv[1], int(sys.argv[2])
magic = b"BOLTMESH"
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
# The two WireGuard type headers the subject rules match, plus the control
# magic, so one control proves all three rules loaded.
for header in (b"\x01\x00\x00\x00", b"\x04\x00\x00\x00"):
    sock.sendto(header + magic + b"\x00" * 96, (ip, port))
PY
sleep 2

# --- the traffic under test --------------------------------------------------

if [[ $SKIP_E2E == 1 ]]; then
  log "SURICATA_SKIP_E2E=1: not running the ladder (control-only run)"
else
  [[ -f $CREDS_FILE ]] || die "no credentials file at $CREDS_FILE (override with BOLTMESH_E2E_CREDS_FILE)"
  api_user=$(unquote "$(sed -n 's/^BOLTMESH_E2E_API_USER=//p' "$CREDS_FILE" | tail -1)")
  api_password=$(unquote "$(sed -n 's/^BOLTMESH_E2E_API_PASSWORD=//p' "$CREDS_FILE" | tail -1)")
  [[ -n $api_user && -n $api_password ]] \
    || die "$CREDS_FILE must set BOLTMESH_E2E_API_USER and BOLTMESH_E2E_API_PASSWORD"
  log "running the app e2e transport ladder"
  BOLTMESH_E2E_API_USER="$api_user" BOLTMESH_E2E_API_PASSWORD="$api_password" \
    "$client_repo/tool/e2e/run_linux_app.sh"
fi

# --- stop capture and flush --------------------------------------------------

log "stopping capture"
sudo kill -INT "$tcpdump_pid" 2>/dev/null || true
wait "$tcpdump_pid" 2>/dev/null || true
tcpdump_pid=""

if [[ -f $workdir/suricata.pid ]]; then
  suricata_pid=$(cat "$workdir/suricata.pid")
fi
sudo kill -TERM "$suricata_pid" 2>/dev/null || true
for _ in $(seq 1 60); do
  sudo kill -0 "$suricata_pid" 2>/dev/null || break
  sleep 0.5
done
suricata_pid=""

# Suricata runs as root; hand the artifacts back so the checker (and the
# operator) can read them without sudo.
sudo chown -R "$(id -u):$(id -g)" "$workdir"

# --- decide ------------------------------------------------------------------

log "checking $(wc -l <"$workdir/eve.json") eve records"
log "artifacts in $workdir"

# The checker is the last command on purpose: with `set -e` its status is the
# run's status, and the EXIT trap preserves it through cleanup. A trailing
# `exit` here would only duplicate that (and confuses ShellCheck's trap
# analysis, SC2329).
python3 "$here/check_flows.py" \
  --eve "$workdir/eve.json" \
  --node "$NODE_IP" \
  --native-port "$NATIVE_PORT" \
  --awg-port "$AWG_PORT" \
  --stream-port "$STREAM_PORT"
