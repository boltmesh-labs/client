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
# It builds into its own root-owned staging directory, never
# BOLTMESH_E2E_WORK_DIR: `run_linux_app.sh` does `rm -rf` on that directory as
# the unprivileged user, so a build left there by this script is a root-owned
# entry that makes the next run fail at its own cleanup step, from an install
# that reported success. It needs no API credentials.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
client_repo="$(cd "$here/../.." && pwd)"

# Root-side build staging; see the header for why this is not the run script's
# workdir. Reset per run rather than reused: a half-written binary from a failed
# build must never be what reaches /usr/libexec.
build_dir="${BOLTMESH_E2E_BUILD_DIR:-/var/tmp/boltmesh-e2e-build}"

[[ $EUID -eq 0 ]] \
  || { printf 'e2e: install_boltmeshd.sh must run as root: sudo tool/e2e/install_boltmeshd.sh\n' >&2; exit 1; }

rm -rf "$build_dir"
install -d -m 700 "$build_dir"

printf '\n=== building boltmeshd from source\n'
(cd "$client_repo/boltmeshd" && CGO_ENABLED=0 go build -trimpath -o "$build_dir/boltmeshd" ./cmd/boltmeshd)

printf '\n=== installing boltmeshd\n'
install -Dm755 "$build_dir/boltmeshd" /usr/libexec/boltmesh/boltmeshd
install -Dm755 "$here/firewall_linux.sh" /usr/local/libexec/boltmesh-e2e-firewall
e2e_user="${SUDO_USER:-}"
[[ -n $e2e_user && $e2e_user != root ]] \
  || { printf 'e2e: invoke through sudo from the unprivileged test user so firewall access can be scoped\n' >&2; exit 1; }
sudoers="/etc/sudoers.d/boltmesh-e2e-firewall-$e2e_user"
printf '%s ALL=(root) NOPASSWD: /usr/local/libexec/boltmesh-e2e-firewall\n' "$e2e_user" > "$sudoers"
chmod 0440 "$sudoers"
visudo -cf "$sudoers"
systemctl restart boltmeshd.service
# Wait for the socket to come back up
for _ in $(seq 1 40); do
  [[ -S /run/boltmesh/boltmeshd.sock ]] && break
  sleep 0.25
done
[[ -S /run/boltmesh/boltmeshd.sock ]] \
  || { printf 'e2e: boltmeshd socket did not come up after restart\n' >&2; exit 1; }

printf '\n=== boltmeshd installed; socket is up\n'
