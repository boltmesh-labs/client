#!/usr/bin/env bash
# Build and install the privileged `boltmeshd` helper from source.
#
# This is the ONLY part of the Linux app e2e that needs root: installing the
# binary into /usr/libexec and restarting its systemd service. Everything
# else (Xvfb, keyring, device clearing, `flutter test`) runs as the normal
# user via `tool/e2e/run_linux_app.sh`, which refuses to run as root because
# `flutter` itself refuses root.
#
# Usage:
#   sudo tool/e2e/install_boltmeshd.sh
#
# It shares BOLTMESH_E2E_WORK_DIR with run_linux_app.sh so the built binary
# path agrees; it needs no API credentials.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
client_repo="$(cd "$here/../.." && pwd)"

workdir="${BOLTMESH_E2E_WORK_DIR:-/tmp/boltmesh-linux-app-e2e}"

[[ $EUID -eq 0 ]] \
  || { printf 'e2e: install_boltmeshd.sh must run as root: sudo tool/e2e/install_boltmeshd.sh\n' >&2; exit 1; }

printf '\n=== building boltmeshd from source\n'
(cd "$client_repo/boltmeshd" && CGO_ENABLED=0 go build -trimpath -o "$workdir/boltmeshd" ./cmd/boltmeshd)

printf '\n=== installing boltmeshd\n'
install -Dm755 "$workdir/boltmeshd" /usr/libexec/boltmesh/boltmeshd
systemctl restart boltmeshd.service
# Wait for the socket to come back up
for _ in $(seq 1 40); do
  [[ -S /run/boltmesh/boltmeshd.sock ]] && break
  sleep 0.25
done
[[ -S /run/boltmesh/boltmeshd.sock ]] \
  || { printf 'e2e: boltmeshd socket did not come up after restart\n' >&2; exit 1; }

printf '\n=== boltmeshd installed; socket is up\n'
