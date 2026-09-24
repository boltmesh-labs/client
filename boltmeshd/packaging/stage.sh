#!/usr/bin/env bash
# Pre-package hook (see `client/distribute_options.yaml`).
#
# Runs after `flutter build linux` and before the deb/rpm maker copies the
# whole bundle into the package. It stages the boltmeshd binary and the
# systemd units inside the bundle so they ship with the app; the package's
# postinstall moves them to /usr/libexec + /usr/lib/systemd/system.
#
# The packager exports BUILD_OUTPUT_DIRECTORY (the Flutter bundle) and runs
# this with the client/ directory as the working directory.  The enrollment
# command is staged as well: package managers do not reliably identify the
# invoking desktop user, so the deb/rpm postinstall can discover it or expose
# an explicit root-run command when discovery is ambiguous.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle="${BUILD_OUTPUT_DIRECTORY:?BUILD_OUTPUT_DIRECTORY is set by the packager}"
stage="$bundle/boltmeshd"

case "$bundle" in
  *arm64* | *aarch64*) goarch=arm64 ;;
  *) goarch=amd64 ;;
esac

mkdir -p "$stage"
(
  cd "$here/.."
  CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" \
    go build -trimpath -ldflags="-s -w" -o "$stage/boltmeshd" ./cmd/boltmeshd
)
install -m 0644 "$here/../deploy/boltmeshd.service" "$stage/boltmeshd.service"
install -m 0644 "$here/../deploy/boltmeshd.socket" "$stage/boltmeshd.socket"
install -m 0644 "$here/../deploy/99-boltmesh-unmanaged.conf" "$stage/99-boltmesh-unmanaged.conf"
install -m 0755 "$here/enroll-user.sh" "$stage/boltmesh-enroll-user"

echo "staged boltmeshd ($goarch) into $stage"
