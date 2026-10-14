#!/usr/bin/env bash
# Root-owned, narrowly scoped firewall control for the desktop E2E.
set -euo pipefail

cmd=${1:-}
if [[ $cmd == clear ]]; then
  [[ $EUID -eq 0 ]] || { echo 'must run as root' >&2; exit 1; }
  if nft list table inet boltmesh_e2e >/dev/null 2>&1; then
    nft delete table inet boltmesh_e2e
  fi
  exit 0
fi
[[ $# -eq 3 && ( $cmd == block || $cmd == unblock ) ]] || {
  echo 'usage: boltmesh-e2e-firewall {block|unblock} IP UDP_PORT' >&2; exit 2;
}
address=$2
port=$3
python3 - "$address" "$port" <<'PY'
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
port = int(sys.argv[2])
if not 1 <= port <= 65535:
    raise SystemExit('port must be between 1 and 65535')
PY
[[ $EUID -eq 0 ]] || { echo 'must run as root' >&2; exit 1; }
family=ip
[[ $address == *:* ]] && family=ip6
if [[ $cmd == block ]]; then
  nft list table inet boltmesh_e2e >/dev/null 2>&1 || {
    nft add table inet boltmesh_e2e
    nft 'add chain inet boltmesh_e2e output { type filter hook output priority -5; policy accept; }'
  }
  nft add rule inet boltmesh_e2e output "$family" daddr "$address" udp dport "$port" drop
else
  # Delete only this tuple, leaving any other active E2E block intact.
  handle=$(nft -a list chain inet boltmesh_e2e output | awk -v ip="$address" -v port="$port" 'index($0, "daddr " ip " udp dport " port " ") {print $NF; exit}')
  [[ -z $handle ]] || nft delete rule inet boltmesh_e2e output handle "$handle"
fi
