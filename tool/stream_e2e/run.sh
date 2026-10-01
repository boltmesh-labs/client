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
#
# Topology. A bridge on the host gives every participant one address family:
#
#   host   br-bm   192.168.100.1/24   (the stub control plane)
#   client ns-bm-client 192.168.100.2/24   boltmeshd + wg-quick
#   node   ns-bm-node   192.168.100.3/24   agentd
#
# The host leg is not decoration: a network namespace has its own loopback, so a
# stub bound to the host's 127.0.0.1 is unreachable from inside either
# namespace. Without the bridge leg the agent could never register.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
client_repo="$(cd "$here/../.." && pwd)"
agent_repo="${BOLTMESH_AGENT_REPO:-$client_repo/../agent}"

keep=0
skip_build=0
bin_dir=""
# BOLTMESH_E2E_DEBUG=1 keeps the network, the work directory and the logs even
# when the run fails, so the live namespaces can be inspected. The default is to
# preserve only the logs, since a leftover bridge and namespaces are easy to
# forget about.
debug_keep="${BOLTMESH_E2E_DEBUG:-0}"
# Run only the client half, against a node this harness does not own.
client_only=0
# A staging_setup.py state file selects the real control plane over the stub.
staging_state=""
# The node's tunnel subnet, for the conf's AllowedIPs.
tunnel_cidr=10.254.0.0/16
for arg in "$@"; do
  case "$arg" in
    --keep) keep=1 ;;
    --skip-build) skip_build=1 ;;
    --bin-dir=*) bin_dir="${arg#*=}" ;;
    --agent-repo=*) agent_repo="${arg#*=}" ;;
    --staging-state=*) staging_state="${arg#*=}" ;;
    --client-only) client_only=1 ;;
    --tunnel-cidr=*) tunnel_cidr="${arg#*=}" ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Fixed names, not random: a leftover from a killed run is then obvious in
# `ip netns list` / `ip link show`, and it is one command to clear.
ns_client=bm-client
ns_node=bm-node
bridge=bm-br
veth_host_c=bm-vh-c
veth_host_n=bm-vh-n
veth_c=bm-vc
veth_n=bm-vn

host_ip=192.168.100.1
client_ip=192.168.100.2
node_ip=192.168.100.3

server_name=stream.harness.test
stream_port=443
wg_port=51820
cp_port=8477

# The agent's seed path is a compiled-in constant (bootstrapSeedPath), not an env
# override, so the harness bind-mounts its seed over it inside the node's mount
# namespace. Declared here so cleanup can see whether this run created the
# directory and is therefore allowed to remove it.
seed_dir=/etc/node-agent
seed_created_dir=0

# Set when this run moves the bridge into firewalld's trusted zone, so cleanup
# only undoes what it did. See the firewalld block below for why this is needed.
firewalld_trusted_bridge=0

# Set when this run had to create the agent's seed file/directory, so cleanup
# only removes what it made. On a real manual node that file holds the bootstrap
# secret and is not ours to delete.
seed_created_file=0

# The firewalld zone the agent binds its WireGuard interface to. Created by the
# AMI build on a provisioned node; created and removed by the harness on a box
# that has never been provisioned.
vpn_zone=vpn
vpn_zone_created=0

workdir="$(mktemp -d /tmp/boltmesh-stream-e2e.XXXXXX)"
client_socket="$workdir/boltmeshd.sock"

log() { printf '\n=== %s\n' "$*"; }
die() { printf 'harness: %s\n' "$*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  die "must run as root (namespaces, veth, and wg are privileged)"
fi

# go is required only when building; with --bin-dir the box needs no toolchain.
required=(ip wg wg-quick python3)
[[ $skip_build -eq 0 && -z $bin_dir ]] && required+=(go)
for tool in "${required[@]}"; do
  command -v "$tool" >/dev/null || die "$tool is required but not installed"
done
if [[ $skip_build -eq 0 && -z $bin_dir ]]; then
  [[ -d "$agent_repo" ]] || die "agent repo not found at $agent_repo (override with --agent-repo)"
fi

teardown_network() {
  # Every call is tolerant: this runs both as a pre-clean before creating the
  # topology and from the exit trap, and "it was not there" is the normal case
  # for the first, not an error.
  #
  # The firewalld undo comes first, while the bridge still exists: removing the
  # interface drops it from any zone anyway, but doing it explicitly keeps the
  # persistent-configuration view honest if the interface outlives the run.
  if [[ ${firewalld_trusted_bridge:-0} -eq 1 ]]; then
    firewall-cmd --zone=trusted --remove-interface="$bridge" >/dev/null 2>&1 || true
    firewalld_trusted_bridge=0
  fi
  # Only if this run made it: a provisioned node's zone is baked into the image
  # and must survive the harness.
  if [[ ${vpn_zone_created:-0} -eq 1 ]]; then
    firewall-cmd --permanent --delete-zone="$vpn_zone" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    vpn_zone_created=0
  fi
  ip netns del "$ns_client" 2>/dev/null || true
  ip netns del "$ns_node" 2>/dev/null || true
  ip link del "$bridge" 2>/dev/null || true
  rm -rf "/etc/netns/$ns_client" "/etc/netns/$ns_node"
  return 0
}

cleanup() {
  local status=$?
  set +e
  for pid_file in "$workdir"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    kill "$(cat "$pid_file")" 2>/dev/null
  done
  if [[ $keep -eq 1 && $status -eq 0 ]] || [[ $debug_keep -eq 1 ]]; then
    log "leaving the network up (--keep); remove with:"
    printf '    ip netns del %s; ip netns del %s; ip link del %s\n' \
      "$ns_client" "$ns_node" "$bridge"
    printf '    firewall-cmd --zone=trusted --remove-interface=%s\n' "$bridge"
  else
    # Client first: it holds the bridge, and tearing the node down first would
    # leave a listener with nothing to reach.
    teardown_network
    if [[ ${seed_created_file:-0} -eq 1 && -e ${seed_dir:-}/bootstrap.env ]]; then
      rm -f "$seed_dir/bootstrap.env"
    fi
    if [[ ${seed_created_dir:-0} -eq 1 && -d ${seed_dir:-} ]]; then
      rmdir "$seed_dir" 2>/dev/null || true
    fi
    # A failed run keeps its logs. Deleting them was a real cost the first time
    # this ran: the one file that said why the stub was unreachable was gone by
    # the time anyone could read it.
    if [[ $status -eq 0 ]]; then
      rm -rf "$workdir"
    else
      printf '\nharness: run failed; logs kept in %s\n' "$workdir" >&2
      printf '  controlplane.log  agent.log  client.log  badpsk.log\n' >&2
    fi
  fi
  exit $status
}
trap cleanup EXIT

# --- build ---------------------------------------------------------------

if [[ -n $bin_dir ]]; then
  [[ -x "$bin_dir/boltmeshd" ]] || die "--bin-dir given but $bin_dir/boltmeshd is missing"
  [[ -x "$bin_dir/agentd" ]] || die "--bin-dir given but $bin_dir/agentd is missing"
  cp "$bin_dir/boltmeshd" "$bin_dir/agentd" "$workdir/"
  log "using prebuilt binaries from $bin_dir"
elif [[ $skip_build -eq 1 ]]; then
  die "--skip-build needs --bin-dir: the work directory is created per run"
else
  log "building boltmeshd and agentd"
  (cd "$client_repo/boltmeshd" && go build -o "$workdir/boltmeshd" ./cmd/boltmeshd)
  (cd "$agent_repo" && go build -o "$workdir/agentd" ./cmd/agentd)
fi

# --- client-only mode ------------------------------------------------------

# Runs just the client half against a node this harness does not own — a real,
# already-registered node on a real host. The full both-ends mode above is the
# better test of the transport itself; this one exists because the node end of a
# production deployment is a machine with a baked firewalld zone and a read-only
# rootfs, and the only way to exercise that end is to point at one that is
# already running.
if [[ $client_only -eq 1 ]]; then
  [[ -n $staging_state ]] || die "--client-only needs --staging-state (there is no stub node to talk to)"
  client_iface=boltmesh0

  log "starting boltmeshd on this host"
  BOLTMESHD_SOCKET="$workdir/boltmeshd.sock" \
  BOLTMESHD_SOCKET_GROUP="" \
  BOLTMESHD_CONFIG_DIR="$workdir/wgconf" \
  BOLTMESHD_LOG_FILE="" \
    "$workdir/boltmeshd" >"$workdir/client.log" 2>&1 &
  echo $! >"$workdir/client.pid"
  for _ in $(seq 1 40); do
    [[ -S "$workdir/boltmeshd.sock" ]] && break
    sleep 0.25
  done
  [[ -S "$workdir/boltmeshd.sock" ]] || die "boltmeshd did not create its socket (see $workdir/client.log)"

  # Idempotent pre-clean: a previous run's interface would make this one's
  # wg-quick fail on the address, which reads as a configuration bug.
  python3 "$here/client.py" --socket "$workdir/boltmeshd.sock" --down >/dev/null 2>&1 || true

  log "bringing the tunnel up through the bridge, against the real node"
  python3 "$here/client.py" \
    --socket "$workdir/boltmeshd.sock" \
    --staging-state "$staging_state" \
    --api-user "$BOLTMESH_E2E_API_USER" \
    --api-password "$BOLTMESH_E2E_API_PASSWORD" \
    --tunnel-cidr "$tunnel_cidr" \
    --state-out "$workdir/client-state.json" \
    || die "the client could not bring the tunnel up (see $workdir/client.log)"

  fail=0
  note_failure() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }
  # No netns argument here: this mode runs in the host namespace, because the
  # node it dials is on the LAN and a bare namespace cannot reach it.
  wg_field() {
    # shellcheck disable=SC2016  # awk program, not shell
    wg show "$1" "$2" 2>/dev/null | awk -v col="$3" '{print $col}' || true
  }

  node_tunnel_ip="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["node_tunnel_ip"])' \
    "$workdir/client-state.json")"

  # On an obfuscated region the client's interface is a userspace AmneziaWG tun,
  # not a kernel WireGuard device, so `wg show` reads nothing and a working tunnel
  # looks dead. The daemon's own status is the equivalent view there; on the
  # native path the kernel's is the stronger one, so it is kept.
  inner_format="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("inner_format","native"))' \
    "$workdir/client-state.json")"
  echo "inner format: $inner_format"
  daemon_field() {
    python3 "$here/client.py" --socket "$workdir/boltmeshd.sock" --status \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1', 0))"
  }
  client_handshake() {
    if [[ "$inner_format" == "awg" ]]; then
      daemon_field lastHandshake
    else
      wg_field "$client_iface" latest-handshakes 2 | head -1
    fi
  }
  client_rx() {
    if [[ "$inner_format" == "awg" ]]; then
      daemon_field rxBytes
    else
      wg_field "$client_iface" transfer 2 | head -1
    fi
  }

  log "asserting on the tunnel's view"
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
  python3 "$here/client.py" --socket "$workdir/boltmeshd.sock" --down \
    >"$workdir/down.log" 2>&1 || true
  sleep 1
  bad_psk="$(printf 'A%.0s' $(seq 1 43))="
  if python3 "$here/client.py" \
      --socket "$workdir/boltmeshd.sock" \
      --staging-state "$staging_state" \
      --api-user "$BOLTMESH_E2E_API_USER" \
      --api-password "$BOLTMESH_E2E_API_PASSWORD" \
      --tunnel-cidr "$tunnel_cidr" \
      --force-psk "$bad_psk" \
      --state-out "$workdir/badpsk-state.json" >"$workdir/badpsk.log" 2>&1; then
    bad_hs=0
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

  # The ladder's floor rests on one claim: an obfuscated region's node runs the
  # AmneziaWG device, so it cannot read a stock datagram — which is why a native
  # start there can only fail, after leaking the plaintext fingerprint. Reproduce
  # that attempt. A stock conf takes the kernel path rather than the userspace
  # device (see `tunnel_linux.go`), so the kernel's own `wg show` is what reports
  # it — the opposite read from the obfuscated run above.
  if [[ "$inner_format" == "awg" ]]; then
    log "negative check: a stock inner format must not reach an obfuscated node"
    python3 "$here/client.py" --socket "$workdir/boltmeshd.sock" --down \
      >"$workdir/down.log" 2>&1 || true
    sleep 1
    if python3 "$here/client.py" \
        --socket "$workdir/boltmeshd.sock" \
        --staging-state "$staging_state" \
        --api-user "$BOLTMESH_E2E_API_USER" \
        --api-password "$BOLTMESH_E2E_API_PASSWORD" \
        --tunnel-cidr "$tunnel_cidr" \
        --force-native \
        --state-out "$workdir/native-state.json" >"$workdir/native.log" 2>&1; then
      # The interface has to exist before the reads below mean anything: an empty
      # `wg show` is also what a missing link produces, and that would pass the
      # check for the wrong reason.
      if ! ip link show "$client_iface" >/dev/null 2>&1; then
        note_failure "a stock conf brought up no $client_iface, so the check proves nothing"
      else
        for _ in $(seq 1 8); do
          ping -c1 -W1 "$node_tunnel_ip" >/dev/null 2>&1 || true
          sleep 1
        done
        native_hs="$(wg_field "$client_iface" latest-handshakes 2 | head -1)"
        native_rx="$(wg_field "$client_iface" transfer 2 | head -1)"
        if [[ -n "$native_hs" && "$native_hs" != "0" ]] || [[ -n "$native_rx" && "$native_rx" != "0" ]]; then
          note_failure "a stock inner format reached an obfuscated node (hs=${native_hs:-none} rx=${native_rx:-0})"
        else
          echo "a stock inner format produced no handshake against the obfuscated node, as it must"
        fi
      fi
    else
      echo "a stock inner format was refused before the tunnel came up, as it must:"
      tail -3 "$workdir/native.log" | sed 's/^/    /'
    fi
  fi

  # Leave the host as we found it: this mode runs in the host namespace, so a
  # leftover interface and its routes would follow the box, not the harness.
  python3 "$here/client.py" --socket "$workdir/boltmeshd.sock" --down >/dev/null 2>&1 || true

  if [[ $fail -ne 0 ]]; then
    log "harness FAILED — logs in $workdir"
    exit 1
  fi
  log "harness PASSED — logs in $workdir"
  exit 0
fi

# --- network -------------------------------------------------------------

log "creating the bridge, namespaces, and veths"
teardown_network
ip netns add "$ns_client"
ip netns add "$ns_node"
ip link add "$bridge" type bridge
ip addr add "$host_ip/24" dev "$bridge"
ip link set "$bridge" up
for pair in "client:$veth_host_c:$veth_c:$ns_client:$client_ip" \
            "node:$veth_host_n:$veth_n:$ns_node:$node_ip"; do
  IFS=: read -r _ host_end ns_end ns addr <<<"$pair"
  ip link add "$host_end" type veth peer name "$ns_end"
  ip link set "$host_end" master "$bridge"
  ip link set "$host_end" up
  ip link set "$ns_end" netns "$ns"
  ip -n "$ns" addr add "$addr/24" dev "$ns_end"
  ip -n "$ns" link set "$ns_end" up
  # Loopback up in both: the client's bridge binds and dials 127.0.0.1, so
  # without lo the client half cannot work at all.
  ip -n "$ns" link set lo up
done

# The node's ingress is served under this name and its certificate is issued for
# it, so the name has to resolve where the client dials. iproute2 bind-mounts
# /etc/netns/<name>/* into the namespace itself, so this is scoped to the
# namespace and never touches the host's resolver.
for ns in "$ns_client" "$ns_node"; do
  mkdir -p "/etc/netns/$ns"
  printf '%s %s\n' "$node_ip" "$server_name" > "/etc/netns/$ns/hosts"
done

ping_out=$(ip netns exec "$ns_client" ping -c1 -W2 "$node_ip" 2>&1) \
  || die "the bridge does not pass traffic: $ping_out"
ping_out=$(ip netns exec "$ns_node" ping -c1 -W2 "$host_ip" 2>&1) \
  || die "the node cannot reach the host leg: $ping_out"
log "network up: client $client_ip, node $node_ip, host $host_ip"

# firewalld, when active, puts a new bridge in the default zone — which rejects
# unsolicited TCP with an ICMP host-prohibited, surfacing inside a namespace as
# "No route to host" while *ping still works*. That combination reads as a
# routing bug and is not one. The bridge is a lab-local segment with no route to
# anywhere, so it goes in the trusted zone for the duration and is removed again
# on the way out; nothing about the host's other interfaces changes.
#
# The WireGuard interface needs the `vpn` zone too. On a provisioned node that
# zone is baked in by the AMI build; on a bare box it does not exist and the
# agent aborts its bootstrap with INVALID_ZONE. firewalld only accepts zone
# creation with --permanent followed by a reload, so the zone is created that way
# — and removed the same way on the way out, but only if this run created it.
#
# Order matters: the reload that activates the new zone also clears runtime
# rules, so the trusted-zone binding is applied after it.
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  if ! firewall-cmd --get-zones | tr ' ' '\n' | grep -qx "$vpn_zone"; then
    log "firewalld: creating the '$vpn_zone' zone the agent expects (runtime, removed on exit)"
    firewall-cmd --permanent --new-zone="$vpn_zone" >/dev/null
    # target ACCEPT is lab-only: a provisioned node's zone carries only the dns
    # service, with masquerade and the vpn-to-internet policy doing the real work.
    # The harness tests an in-tunnel ping, not egress, so the permissive target
    # is the smallest thing that lets the interface attach.
    firewall-cmd --permanent --zone="$vpn_zone" --set-target=ACCEPT >/dev/null
    firewall-cmd --reload >/dev/null
    vpn_zone_created=1
  fi
  log "firewalld is active; placing $bridge in the trusted zone"
  if ! firewall-cmd --zone=trusted --add-interface="$bridge" >/dev/null 2>&1; then
    die "could not place $bridge in firewalld's trusted zone; the datapath would be filtered"
  fi
  firewalld_trusted_bridge=1
fi

# --- control plane source -------------------------------------------------

# Two sources, and they prove different things. The stub fixture builds the
# descriptors by hand, so it proves the transport but says nothing about the
# contract. The real control plane proves the schemas actually produce something
# the helpers accept — which is the only way to catch a field name drifting
# between three repos in three languages.
api_base=""
bootstrap_secret=""
client_priv=""
client_pub=""

if [[ -n $staging_state ]]; then
  [[ -r $staging_state ]] || die "--staging-state $staging_state is not readable"
  [[ -n ${BOLTMESH_E2E_API_USER:-} && -n ${BOLTMESH_E2E_API_PASSWORD:-} ]] || die \
    "--staging-state also needs BOLTMESH_E2E_API_USER and BOLTMESH_E2E_API_PASSWORD in the environment"

  # Read the state file with python and emit one TAB-separated line. `read` with
  # the default IFS would split the private key on any space, and jq is not
  # necessarily installed.
  state_line="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("\t".join([d["api_base"], d["server_name"], str(d["stream_port"]),
                 d["bootstrap_secret"], d["client_private_key"], d["client_public_key"]]))
' "$staging_state")" || die "could not parse $staging_state"
  IFS=$'\t' read -r api_base server_name stream_port bootstrap_secret client_priv client_pub \
    <<<"$state_line"
  [[ -n $api_base && -n $bootstrap_secret ]] || die "$staging_state is missing required fields"
  # The real API base already carries /v1, and the agent appends nothing of its
  # own when the base already has it.
  api_seed="$api_base"
  log "real control plane: $api_base (node endpoint $server_name:$stream_port)"
else
  # The client device's WireGuard keypair. Generated up front so the stub can
  # serve the public half in peers-sync from the node's very first fetch, and so
  # the client's conf and the node's peer agree without a mid-run race.
  client_priv="$(wg genkey)"
  client_pub="$(printf '%s' "$client_priv" | wg pubkey)"

  log "starting the stub control plane on $host_ip:$cp_port"
  python3 "$here/controlplane.py" \
    --host "$host_ip" \
    --port "$cp_port" \
    --server-name "$server_name" \
    --stream-port "$stream_port" \
    --wg-port "$wg_port" \
    --client-public-key "$client_pub" \
    >"$workdir/controlplane.log" 2>&1 &
  echo $! >"$workdir/controlplane.pid"

  api_base="http://$host_ip:$cp_port"
  # The agent appends the version prefix itself, and the stub routes are under
  # /v1, so the seed carries it while the client half (which builds absolute
  # paths like /harness/state) gets the bare origin.
  api_seed="$api_base/v1"
  reachable=0
  for _ in $(seq 1 40); do
    if ip netns exec "$ns_node" python3 -c \
        "import socket;s=socket.create_connection(('$host_ip',$cp_port),0.5);s.close()" 2>/dev/null; then
      reachable=1
      break
    fi
    sleep 0.25
  done
  [[ $reachable -eq 1 ]] || {
    printf '\n--- stub control plane log ---\n' >&2
    cat "$workdir/controlplane.log" >&2 || true
    printf '\n--- host address on %s ---\n' "$bridge" >&2
    ip -o addr show dev "$bridge" >&2 || true
    printf '--- node leg ---\n' >&2
    ip netns exec "$ns_node" ip -o addr show >&2 || true
    die "the stub control plane is unreachable from the node (log above)"
  }
fi

# --- node ----------------------------------------------------------------

log "starting agentd in $ns_node"
if [[ ! -d $seed_dir ]]; then
  mkdir -p "$seed_dir"
  seed_created_dir=1
fi
# The bind target must exist as a file: `mount --bind` will not create it, and
# "mount point does not exist" is the error that produces.
if [[ ! -e "$seed_dir/bootstrap.env" ]]; then
  : > "$seed_dir/bootstrap.env"
  chmod 600 "$seed_dir/bootstrap.env"
  seed_created_file=1
fi
cat > "$workdir/bootstrap.env" <<EOF
API_BASE_URL=$api_seed
NODE_BOOTSTRAP_SECRET=$bootstrap_secret
EOF
chmod 600 "$workdir/bootstrap.env"
# The bind and the exec must happen inside ONE `ip netns exec`: each invocation
# unshares its own mount namespace, making this namespace's mounts private, so a
# bind done in one invocation is gone before the next one starts. Doing them
# separately left agentd reading the host's empty seed file.
# ALLOW_INSECURE_HTTP: the agent refuses cleartext http to a non-loopback host
# by default, because bearer tokens travel in headers and the node has no way to
# know the network is trusted. The harness's stub is on the lab bridge, which is
# not loopback, so the override is required — and it is the only reason it is
# here. Nothing in this harness should be pointed at a real control plane with
# cleartext http.
# shellcheck disable=SC2016  # $1/$2/$3 are expanded by the inner bash, not here
ip netns exec "$ns_node" env LOG_LEVEL=DEBUG ALLOW_INSECURE_HTTP=true \
  bash -c 'mount --bind "$1" "$2" || exit 1; exec "$3" bootstrap' \
  _ "$workdir/bootstrap.env" "$seed_dir/bootstrap.env" "$workdir/agentd" \
  >"$workdir/agent.log" 2>&1 &
echo $! >"$workdir/agent.pid"

# --- client --------------------------------------------------------------

log "starting boltmeshd in $ns_client"
# SOCKET_GROUP is emptied because the daemon's default group ("boltmesh") is an
# install-time artifact of the packaged deployment and does not exist on a bare
# box. Empty means root-only, which is what a lab run needs.
ip netns exec "$ns_client" env \
  BOLTMESHD_SOCKET="$client_socket" \
  BOLTMESHD_SOCKET_GROUP="" \
  BOLTMESHD_CONFIG_DIR="$workdir/wgconf" \
  BOLTMESHD_LOG_FILE="" \
  "$workdir/boltmeshd" \
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
  --control-plane "$api_base" \
  --server "$server_name:$stream_port" \
  --server-name "$server_name" \
  --inline-client-private "$client_priv" \
  --state-out "$workdir/client-state.json" \
  || die "the client could not bring the tunnel up (see $workdir/client.log)"

# --- assertions ----------------------------------------------------------

fail=0
note_failure() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

# The two interfaces are not the same name: the node's comes from the control
# plane's interface_name, while boltmeshd manages a fixed `boltmesh0`. Reading
# the wrong name is not a loud error — `wg show` exits non-zero, and under
# `set -o pipefail` inside a command substitution that kills the script with no
# message at all. So every read below is guarded and every name is explicit.
node_iface=wg0
client_iface=boltmesh0

wg_field() {
  # $1 netns, $2 iface, $3 wg subcommand, $4 column number.
  #
  # The awk program lives here and nowhere else. Passing one in from each call
  # site means an awk `$2` sitting in shell single quotes, which shellcheck reads
  # as an unexpanded shell variable (SC2016) at every one of those sites; keeping
  # it in one place needs one suppression instead of seven.
  #
  # Never fails the script: an absent interface yields an empty string, which the
  # assertions then report by name.
  # shellcheck disable=SC2016  # the awk program is awk's, not the shell's
  ip netns exec "$1" wg show "$2" "$3" 2>/dev/null | awk -v col="$4" '{print $col}' || true
}

log "asserting on the kernel's view"

# A missing interface is a harness or startup failure, not a handshake result,
# and it is worth saying so plainly rather than reporting "no handshake".
for ns_iface in "$ns_client:$client_iface" "$ns_node:$node_iface"; do
  ns="${ns_iface%%:*}"; iface="${ns_iface##*:}"
  if ! ip netns exec "$ns" ip link show "$iface" >/dev/null 2>&1; then
    note_failure "interface $iface does not exist in $ns"
  fi
done

# Waiting rather than reading once: WireGuard's first initiation only happens
# when there is traffic, so a single read can land before any packet was sent.
handshakes_ok=0
for _ in $(seq 1 30); do
  c_hs="$(wg_field "$ns_client" "$client_iface" latest-handshakes 2 | head -1)"
  n_hs="$(wg_field "$ns_node" "$node_iface" latest-handshakes 2 | head -1)"
  if [[ -n "$c_hs" && "$c_hs" != "0" && -n "$n_hs" && "$n_hs" != "0" ]]; then
    handshakes_ok=1
    break
  fi
  # Nudge traffic: a quiet tunnel may not have initiated yet.
  ip netns exec "$ns_client" ping -c1 -W1 10.254.0.1 >/dev/null 2>&1 || true
  sleep 0.5
done
[[ $handshakes_ok -eq 1 ]] || note_failure "no completed handshake on both interfaces"
echo "client $client_iface handshakes: $(wg_field "$ns_client" "$client_iface" latest-handshakes 2 | tr '\n' ' ')"
echo "node   $node_iface handshakes: $(wg_field "$ns_node" "$node_iface" latest-handshakes 2 | tr '\n' ' ')"

# The two traps from the README: a bare kernel wg device installs no routes for
# peer allowed-ips, and a local address short-circuits routing. Asserting only on
# ping would pass with zero real traffic, so the counters are checked too.
# `wg show <iface> transfer` prints one tab-separated row per peer with no
# header: public key, rx bytes, tx bytes. There is no "received" word in it —
# that belongs to the human-readable `wg show` output, and selecting on it
# silently yields nothing, which reads as "zero traffic" and accuses a working
# tunnel.
c_rx="$(wg_field "$ns_client" "$client_iface" transfer 2 | head -1)"
echo "client received: ${c_rx:-0} bytes over WireGuard"
if [[ -z "${c_rx:-}" || "$c_rx" == "0" ]]; then
  note_failure "the client interface received nothing over WireGuard"
fi

log "pinging across the tunnel"
# The node brings its interface up through the agent, which does not install
# peer routes, and a bare kernel wg device never does. wg-quick adds this on the
# client; the node's reply needs it too.
ip netns exec "$ns_node" ip route add 10.254.0.0/16 dev "$node_iface" 2>/dev/null || true
if ping_log="$(ip netns exec "$ns_client" ping -c3 -W2 10.254.0.1 2>&1)"; then
  echo "$ping_log" | tail -3
else
  echo "$ping_log"
  note_failure "the in-tunnel ping failed"
fi
grep -q "0% packet loss" <<<"$ping_log" || note_failure "the in-tunnel ping lost packets"

log "negative check: a wrong PSK must not authenticate"
# A device presenting the wrong credential must not be able to move a single
# byte. This is what would catch the credential store being keyed on something
# other than the client id, or the key proof being skipped outright — both of
# which every positive check above passes happily.
#
# The credential is only observable through its *effect*, and two things make the
# naive version of this test useless:
#
#   - `up` succeeds regardless. The kernel interface and its route come up
#     locally; the kernel knows nothing about a stream credential. So "up
#     returned success" says nothing.
#   - a tunnel already up keeps handshaking on its own. So the working tunnel is
#     torn down first, making a fresh handshake unambiguous evidence.
#
# What must not happen is a handshake. Mutate the PSK rather than the client id:
# a bad client id is refused by the lookup (unknown device), while a bad PSK is
# refused by the key proof, and the proof is the part worth exercising.
ip netns exec "$ns_client" python3 "$here/client.py" \
  --socket "$client_socket" --down >"$workdir/down.log" 2>&1 || true
sleep 1

bad_psk="$(printf 'A%.0s' $(seq 1 43))="
if ip netns exec "$ns_client" python3 "$here/client.py" \
    --socket "$client_socket" \
    --control-plane "$api_base" \
    --server "$server_name:$stream_port" \
    --server-name "$server_name" \
    --inline-client-private "$client_priv" \
    --force-psk "$bad_psk" \
    --state-out "$workdir/badpsk-state.json" >"$workdir/badpsk.log" 2>&1; then
  # Give it every chance: nudge traffic, then wait out several handshake retries.
  for _ in $(seq 1 8); do
    ip netns exec "$ns_client" ping -c1 -W1 10.254.0.1 >/dev/null 2>&1 || true
    sleep 1
  done
  bad_hs="$(wg_field "$ns_client" "$client_iface" latest-handshakes 2 | head -1)"
  bad_rx="$(wg_field "$ns_client" "$client_iface" transfer 2 | head -1)"
  if [[ -n "$bad_hs" && "$bad_hs" != "0" ]] || [[ -n "$bad_rx" && "$bad_rx" != "0" ]]; then
    note_failure "a session presenting a mutated PSK completed a handshake (hs=${bad_hs:-none} rx=${bad_rx:-0})"
  else
    echo "a mutated PSK produced no handshake and moved no bytes, as it must"
  fi
else
  echo "a mutated PSK was refused before the tunnel came up, as it must:"
  tail -3 "$workdir/badpsk.log" | sed 's/^/    /'
fi

# --- result --------------------------------------------------------------

if [[ $fail -ne 0 ]]; then
  log "harness FAILED — logs in $workdir"
  exit 1
fi
log "harness PASSED — logs in $workdir"
