# boltmeshd

Privileged helper for the BoltMesh client. It owns the WireGuard interface
lifecycle and every privileged read, and exposes them to the unprivileged
Flutter app over a local transport. The app therefore never runs `sudo`, `wg`,
`wg-quick`, or an elevated GUI.

## Status per platform

| Platform | Transport | Data plane | State |
| --- | --- | --- | --- |
| Linux | Unix socket, systemd socket-activation | kernel `wireguard` via `wg-quick` + `wgctrl` | shipping |
| Windows | named pipe `\\.\pipe\boltmesh\boltmeshd` | WireGuard-for-Windows tunnel service + `wireguard.dll` | shipping |
| macOS | Unix socket, launchd LaunchDaemon | **userspace `wireguard-go` over `utun`** | **build-tagged, untested on hardware** |

## macOS design

macOS has **no kernel WireGuard module**, and `wgctrl` — the library the Linux
backend reads the device through — ships `os_linux.go`, `os_windows.go`,
`os_freebsd.go` and `os_openbsd.go`, but no darwin. There is also no `wg-quick`
for macOS. So the macOS backend cannot reuse either existing data plane.

It runs the WireGuard data plane **in userspace**, in the daemon process, over
a `utun` device, and configures it through the device's UAPI protocol — the same
architecture the upstream WireGuard macOS app uses (`wireguard-go-bridge`).

```text
client ──unix socket──> boltmeshd (root, LaunchDaemon)
                          ├── utunN  <──> wireguard-go device (in-process)
                          ├── ifconfig/route  (addresses + default route)
                          └── /etc/resolver    (tunnel DNS, restored on down)
```

### What this means for security

* The client sends the same validated wg-quick text it sends everywhere.
  `config.Validate` still rejects `PreUp`/`PostUp`/`PreDown`/`PostDown`/
  `SaveConfig`, so the client cannot turn `up` into root code execution.
* `[Interface] Address` and `DNS` are **not** forwarded to the device: it
  rejects unknown keys, and it has no concept of either. The backend applies
  them itself, which is also what lets one client config drive all three
  platforms.
* Privileged tools (`ifconfig`, `route`, `netstat`) are resolved from a fixed
  `/sbin:/usr/sbin:/bin:/usr/bin` list, never `PATH` — the daemon runs as root,
  so a caller-influenced `PATH` would otherwise execute as root.
* The config directory must be root-owned and inaccessible beyond its owner, or
  the daemon refuses to start: a user-writable config directory would let a
  standard account replace the config the daemon later reads.
* The socket is `root:<group>` 0660 (empty group ⇒ `root:root` 0600).

### Honest status: this is not proven on hardware

Everything in the macOS backend is behind `//go:build darwin`, so the Linux and
Windows runners **cannot execute it**. What CI does verify:

* it compiles for `darwin/amd64` and `darwin/arm64`;
* `go vet` type-checks the darwin-tagged files **and their tests**;
* `golangci-lint` runs with `GOOS=darwin`;
* the UAPI translation layer (`internal/tunnel/uapi.go`) and the client's
  config validation are platform-independent and **are** unit-tested on Linux.

What is **not** verified, because it needs a Mac with root: the utun lifecycle,
the route and DNS manipulation, and the end-to-end tunnel. The darwin-tagged
tests in `tunnel_darwin_test.go` cover the manager's sequencing against fakes
and are written to run on a macOS runner; they have never been executed.

Treat the macOS data plane as unproven. Running them on a Mac is the next step,
not a formality.

## Build

```sh
make build               # linux + windows + darwin binaries in ignored bin/
make build-darwin        # darwin only (cross-compiles from any host)
make lint-darwin         # lint with GOOS=darwin; the only way the macOS
                         # backend is ever analysed on Linux
make test-darwin         # type-checks the darwin files and their tests
```

`make test` runs the host-platform suite. The darwin-tagged tests need a macOS
host (a `utun` interface and root) and run only there.

## Protocol

The socket/pipe speaks JSON, one request per connection. Operations: `up`,
`down`, `status`, `getActivePeer`, `killGhost`. See `internal/protocol`.

On Windows the client additionally authenticates the server end of the
connection: the connected pipe's server process must be the process the SCM
reports for the `boltmeshd` service, so an unprivileged process that
pre-created the pipe name cannot obtain a WireGuard config.

## Logs

JSON lines, persisted so a failure survives a restart:

* Linux: `/var/log/boltmesh/boltmeshd.log`
* Windows: `%ProgramData%\BoltMesh\logs\boltmeshd.log`
* macOS: `/var/log/boltmesh/boltmeshd.log` (plus `/var/log/boltmesh/launchd.log`
  for anything launchd itself reports)
