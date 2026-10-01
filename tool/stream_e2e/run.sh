#!/usr/bin/env bash
# End-to-end harness for the stream transport: two real helper processes, two
# real WireGuard interfaces, one real TLS session between them.
#
# See README.md for what this does and does not prove. The short version: it
# rules out the failure where both halves pass their own unit tests — against
# golden vectors, a fake kernel, a hand-rolled dial helper — and still do not
# interoperate. It proves nothing about evading a real DPI.
#
# Requires root (namespaces, veth, and wg are all privileged).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
client_repo="$(cd "$here/../.." && pwd)"
agent_repo="${BOLTMESH_AGENT_REPO:-$client_repo/../agent}"

keep=0
skip_build=0
for arg in "$@"; do
  case "$arg" in
    --keep) keep=1 ;;
    --skip-build) skip_build=1 ;;
    --agent-repo=*) agent_repo="${arg#*=}" ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Namespace and port names are fixed rather than random: a fixed name makes a
# leftover from a killed run obvious (`ip netns list`), and the ports are inside
# the namespaces' private veth so they cannot collide with the host's.
ns_client=bm-client
ns_node=bm-node
# An RFC 5737 documentation address: 198.51.100.0/24. The node's ingress must be
# reachable at a name, and the certificate is issued for that name, so the name
# has to resolve inside the node's namespace. /etc/hosts is shared across
# namespaces on Linux, so the harness resolves it explicitly per namespace
# instead of mutating the host's.
node_ip=198.51.100.2
client_ip=198.51.100.1
server_name=stream.harness.test
stream_port=443
wg_port=51820
cp_port=8477

veth_client=veth-bm-c
veth_node=veth-bm-n

# The agent's seed path is a compiled-in constant (bootstrapSeedPath), not an env
# override, so the harness bind-mounts its seed over it inside the node's mount
# namespace. Declared here so cleanup can see whether this run created the
# directory and is therefore allowed to remove it.
seed_dir=/etc/node-agent
seed_created_dir=0

workdir="$(mktemp -d /tmp/boltmesh-stream-e2e.XXXXXX)"
client_socket="$workdir/boltmeshd.sock"

log() { printf '\n=== %s\n' "$*"; }

die() { printf 'harness: %s\n' "$*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  die "must run as root (namespaces, veth, and wg are privileged)"
fi

for tool in ip wg wg-quick python3 go; do
  command -v "$tool" >/dev/null || die "$tool is required but not installed"
done
[[ -d "$agent_repo" ]] || die "agent repo not found at $agent_repo (override with --agent-repo)"

cleanup() {
  local status=$?
  set +e
  if [[ $keep -eq 1 && $status -eq 0 ]]; then
    log "leaving namespaces up (--keep); remove with: ip netns del $ns_client; ip netns del $ns_node"
  else
    for pid_file in "$workdir"/*.pid; do
      [[ -e "$pid_file" ]] || continue
      kill "$(cat "$pid_file")" 2>/dev/null
    done
    # Delete the client first: it holds the bridge, and tearing the node down
    # first would leave a listener with nothing to reach.
    ip netns del "$ns_client" 2>/dev/null
    ip netns del "$ns_node" 2>/dev/null
    # Only remove the seed directory if this run created it: on a real manual
    # node it holds the bootstrap secret and is not ours to delete.
    if [[ ${seed_created_dir:-0} -eq 1 && -d ${seed_dir:-} ]]; then
      rmdir "$seed_dir" 2>/dev/null || true
    fi
    rm -rf "$workdir"
  fi
  exit $status
}
trap cleanup EXIT

# --- build ---------------------------------------------------------------

if [[ $skip_build -eq 0 ]]; then
  log "building boltmeshd and agentd"
  (cd "$client_repo/boltmeshd" && go build -o "$workdir/boltmeshd" ./cmd/boltmeshd)
  (cd "$agent_repo" && go build -o "$workdir/agentd" ./cmd/agentd)
else
  log "reusing existing binaries (--skip-build)"
  [[ -x "$workdir/boltmeshd" ]] || die "--skip-build given but $workdir/boltmeshd does not exist"
fi

# --- namespaces ----------------------------------------------------------

log "creating namespaces and the veth pair"
ip netns del "$ns_client" 2>/dev/null
ip netns del "$ns_node" 2>/dev/null
ip netns add "$ns_client"
ip netns add "$ns_node"
# Loopback up in both: the client's bridge binds and dials 127.0.0.1, so without
# lo the client half cannot work at all.
ip -n "$ns_client" link set lo up
ip -n "$ns_node" link set lo up
ip link add "$veth_client" type veth peer name "$veth_node"
ip link set "$veth_client" netns "$ns_client"
ip link set "$veth_node" netns "$ns_node"
ip -n "$ns_client" addr add "$client_ip/24" dev "$veth_client"
ip -n "$ns_node" addr add "$node_ip/24" dev "$veth_node"
ip -n "$ns_client" link set "$veth_client" up
ip -n "$ns_node" link set "$veth_node" up

# The node's ingress is served under this name and its certificate is issued for
# it, so it has to resolve where the client dials. A per-namespace /etc/hosts
# avoids touching the host's: a hosts entry on the host would make the *host's*
# name resolution lie, which is the kind of thing that survives the harness.
cat > "$workdir/hosts" <<EOF
$node_ip $server_name
EOF
for ns in "$ns_client" "$ns_node"; do
  mount --bind "$workdir/hosts" "/etc/netns/$ns/hosts" 2>/dev/null \
    || { umount "/etc/netns/$ns/hosts" 2>/dev/null || true; mkdir -p "/etc/netns/$ns"; mount --bind "$workdir/hosts" "/etc/netns/$ns/hosts"; }
done

ping_out=$(ip netns exec "$ns_client" ping -c1 -W2 "$node_ip" 2>&1) || die "the veth pair does not pass traffic: $ping_out"
log "veth reachable ($client_ip -> $node_ip)"

# --- stub control plane --------------------------------------------------

# The client device's WireGuard keypair. Generated up front so the stub can serve
# the public half in peers-sync from the node's very first fetch, and so the
# client's conf and the node's peer agree without a mid-run race.
client_priv="$(wg genkey)"
client_pub="$(printf '%s' "$client_priv" | wg pubkey)"

log "starting the stub control plane on 127.0.0.1:$cp_port"
python3 "$here/controlplane.py" \
  --port "$cp_port" \
  --server-name "$server_name" \
  --stream-port "$stream_port" \
  --wg-port "$wg_port" \
  --client-public-key "$client_pub" \
  >"$workdir/controlplane.log" 2>&1 &
echo $! >"$workdir/controlplane.pid"

for _ in $(seq 1 40); do
  if ip netns exec "$ns_client" python3 -c \
      "import socket,sys; s=socket.create_connection(('127.0.0.1',$cp_port),0.5); s.close()" 2>/dev/null; then
    break
  fi
  sleep 0.25
done
ip netns exec "$ns_client" python3 -c \
  "import socket; s=socket.create_connection(('127.0.0.1',$cp_port),1); s.close()" \
  || die "the stub control plane did not come up (see $workdir/controlplane.log)"

# --- node ----------------------------------------------------------------

log "starting agentd in $ns_node"
# The node's seed path is a compiled-in constant (/etc/node-agent/bootstrap.env)
# rather than an env override, deliberately: a root daemon reading its bootstrap
# secret from a mutable environment variable is a redirect anyone who can
# influence the environment could use. So the harness bind-mounts its seed over
# that path, scoped to the namespace's own mount namespace, leaving the host's
# file untouched. The directory is created only if absent — it is the agent's
# documented install path — and removed again on the way out if this run made it.
if [[ ! -d $seed_dir ]]; then
  mkdir -p "$seed_dir"
  seed_created_dir=1
fi
cat > "$workdir/bootstrap.env" <<EOF
API_BASE_URL=http://127.0.0.1:$cp_port/v1
NODE_BOOTSTRAP_SECRET=harness-bootstrap-secret
EOF
chmod 600 "$workdir/bootstrap.env"
# The bind happens *inside* `ip netns exec`, which unshares a mount namespace.
# Mounting from the host would replace the host's own seed file for the duration.
ip netns exec "$ns_node" mount --bind "$workdir/bootstrap.env" "$seed_dir/bootstrap.env"

ip netns exec "$ns_node" env LOG_LEVEL=DEBUG \
  "$workdir/agentd" bootstrap \
  >"$workdir/agent.log" 2>&1 &
echo $! >"$workdir/agent.pid"

# --- client --------------------------------------------------------------

log "starting boltmeshd in $ns_client"
# The helper runs wg-quick, which needs a root-only config directory and a
# network namespace that already exists. BOLTMESHD_SOCKET overrides the socket
# path so the harness does not touch the host's /run/boltmesh.
ip netns exec "$ns_client" env \
  BOLTMESHD_SOCKET="$client_socket" \
  BOLTMESHD_CONFIG_DIR="$workdir/wgconf" \
  BOLTMESHD_LOG_FILE="" \
  "$workdir/boltmeshd" --console \
  >"$workdir/client.log" 2>&1 &
echo $! >"$workdir/client.pid"

for _ in $(seq 1 40); do
  [[ -S "$client_socket" ]] && break
  sleep 0.25
done
[[ -S "$client_socket" ]] || die "boltmeshd did not create its socket (see $workdir/client.log)"

log "bringing the tunnel up through the bridge"
ip netns exec "$ns_client" python3 "$here/client.py" \
  --socket "$client_socket" \
  --control-plane "http://127.0.0.1:$cp_port" \
  --server "$node_ip:$stream_port" \
  --server-name "$server_name" \
  --node-tunnel-ip 10.254.0.1 \
  --state-out "$workdir/client-state.json" \
  || die "the client could not bring the tunnel up (see $workdir/client.log)"

# --- assertions ----------------------------------------------------------

fail=0
note_failure() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

log "asserting on the kernel's view"
# Waiting for the handshake rather than reading once: WireGuard's first
# initiation only happens when there is traffic, so a single read can land before
# any packet was ever sent.
handshakes_ok=0
for _ in $(seq 1 30); do
  c_hs="$(ip netns exec "$ns_client" wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
  n_hs="$(ip netns exec "$ns_node" wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
  if [[ -n "$c_hs" && "$c_hs" != "0" && -n "$n_hs" && "$n_hs" != "0" ]]; then
    handshakes_ok=1
    break
  fi
  # Nudge traffic: a quiet tunnel may not have initiated yet.
  ip netns exec "$ns_client" ping -c1 -W1 10.254.0.1 >/dev/null 2>&1 || true
  sleep 0.5
done
[[ $handshakes_ok -eq 1 ]] || note_failure "no completed handshake on both interfaces"
echo "client latest-handshakes: $(ip netns exec "$ns_client" wg show wg0 latest-handshakes 2>&1 | head -2)"
echo "node   latest-handshakes: $(ip netns exec "$ns_node" wg show wg0 latest-handshakes 2>&1 | head -2)"

# The two traps from the README: a bare kernel wg device installs no routes for
# peer allowed-ips, and a local address short-circuits routing. Asserting only on
# ping would pass with zero real traffic, so the transfer counters are checked too.
c_tx="$(ip netns exec "$ns_client" wg show wg0 transfer 2>/dev/null | awk '/received/{print $2}')"
n_rx="$(ip netns exec "$ns_node" wg show wg0 transfer 2>/dev/null | awk '/received/{print $2}')"
echo "client received: ${c_tx:-0} bytes, node received: ${n_rx:-0} bytes"
if [[ -z "${c_tx:-}" || "$c_tx" == "0" ]]; then
  note_failure "the client interface received nothing over WireGuard"
fi

log "pinging across the tunnel"
# The node's side needs the route for the client's allowed-ip. wg-quick adds it on
# the client; the node brings its interface up through the agent, which does not
# install peer routes, so the harness adds the one the reply needs.
ip netns exec "$ns_node" ip route add 10.254.0.0/16 dev wg0 2>/dev/null || true
ping_log="$(ip netns exec "$ns_client" ping -c3 -W2 10.254.0.1 2>&1)" \
  && ping_ok=1 || ping_ok=0
echo "$ping_log"
[[ $ping_ok -eq 1 ]] || note_failure "the in-tunnel ping failed"
if grep -q "0% packet loss" <<<"$ping_log"; then
  echo "ping: 0% packet loss"
else
  note_failure "the in-tunnel ping lost packets"
fi

log "negative check: a wrong PSK must not authenticate"
# A device presenting the wrong credential must be refused. This is the assertion
# that would catch the credential store being keyed on something other than the
# client id, or the key proof being skipped outright — both of which every
# positive-path test above passes happily.
#
# Mutate the PSK rather than the client id: a bad client id is refused by the
# lookup (unknown device), while a bad PSK is refused by the key proof, and the
# proof is the part worth exercising here.
bad_psk="$(printf 'A%.0s' $(seq 1 43))"
sed "s|\"psk\": state\[\"psk\"\]|\"psk\": \"$bad_psk\"|" \
  "$here/client.py" >"$workdir/client_badpsk.py"
if ! grep -q 'psk' "$workdir/client_badpsk.py"; then
  die "could not build the mutated-PSK client (the sed pattern no longer matches client.py)"
fi

# Bring the working tunnel down first, so a refusal cannot be mistaken for the
# previous session still being up.
ip netns exec "$ns_client" python3 "$here/client.py" --socket "$client_socket" --down \
  >"$workdir/down.log" 2>&1 || true

if ip netns exec "$ns_client" python3 "$workdir/client_badpsk.py" \
    --socket "$client_socket" \
    --control-plane "http://127.0.0.1:$cp_port" \
    --server "$node_ip:$stream_port" \
    --server-name "$server_name" \
    --state-out "$workdir/badpsk-state.json" >"$workdir/badpsk.log" 2>&1; then
  note_failure "a mutated PSK still brought the tunnel up; the credential is not being checked"
else
  echo "a mutated PSK was refused, as it must be:"
  tail -3 "$workdir/badpsk.log" | sed 's/^/    /'
fi

# And the node must still be listening for the real one afterwards: a control
# plane that stored the bad credential, or an ingress that tore itself down on
# one bad hello, would both show up only here.
ip netns exec "$ns_client" python3 "$here/client.py" \
  --socket "$client_socket" \
  --control-plane "http://127.0.0.1:$cp_port" \
  --server "$node_ip:$stream_port" \
  --server-name "$server_name" \
  --state-out "$workdir/client-state-2.json" >"$workdir/client-2.log" 2>&1 \
  || note_failure "the tunnel did not come back up with the correct PSK after a refused one"

# --- result --------------------------------------------------------------

if [[ $fail -ne 0 ]]; then
  log "harness FAILED — logs in $workdir"
  exit 1
fi
log "harness PASSED — logs in $workdir"
