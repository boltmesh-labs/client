# boltmeshd

Privileged helper for the BoltMesh client. It owns the WireGuard interface
lifecycle and every privileged read, and exposes them to the unprivileged
Flutter app over a local transport. The app therefore never runs `sudo`, `wg`,
`wg-quick`, or an elevated GUI.

## Status per platform

| Platform | Transport | Data plane | State |
| --- | --- | --- | --- |
| Linux | Unix socket, systemd socket-activation | kernel `wireguard` via `wg-quick` + `wgctrl`; in-process **AmneziaWG** over a tun for configs carrying the obfuscation directives | shipping |
| Windows | named pipe `\\.\pipe\boltmesh\boltmeshd` | WireGuard-for-Windows tunnel service + `wireguard.dll` | shipping |
| macOS | Unix socket, launchd LaunchDaemon | **userspace `wireguard-go` over `utun`** | **build-tagged, untested on hardware** |

## Stream transport (Linux, opt-in per `up`)

A client may send a `transport` spec with `up` (mode `stream`), which carries
the tunnel's UDP datagrams to the real server inside a TLS session that
middleboxes treat as ordinary HTTPS — the rung for networks that block or
fingerprint WireGuard's own UDP. The peer's `Endpoint` is then a loopback
address and the daemon runs the bridge in-process for the tunnel's lifetime:

```text
client ──unix socket──> boltmeshd (root)
                         ├── boltmesh/stream  (in-process, binds loopback only)
                         │     127.0.0.1:51821 ◀──datagrams── wg-quick
                         │             └──TLS 1.3──> vpn.example.net:443
                         └── wg-quick: Endpoint = 127.0.0.1:51821
```

Two addresses matter, and the client must set both. `listen` is what the peer's
`Endpoint` points at; `deliver` is the tunnel's own `ListenPort`, where the
server's datagrams are handed back. The second is explicit because it cannot be
derived — an interface with `ListenPort = 0` takes an ephemeral port nobody can
guess — so the client pins the local port when it selects this rung.

### What authenticates the two ends

`boltmesh/stream` (a module shared with the Android native build) owns the wire
format, and it is deliberately the whole protocol surface: length-prefixed
frames over TLS, nothing else.

- The **node** is authenticated by a certificate **pin** (SHA-256 of the leaf
  SPKI, several allowed so a node can rotate its key). There is no CA chain to
  trust: the peer is a single known node whose key the control plane hands out.
- The **device** is authenticated by a per-device **PSK**, proven with an
  AES-256-GCM tag under `HKDF-SHA256(psk, salt = client id)`. The tag is the
  credential, so the node can check it without decrypting anything. The hello
  carries a timestamp as *additional data*, which both binds the proof to a
  moment and lets the node check freshness before it does any AEAD work — so a
  captured hello stops authenticating once the 5-minute window closes.
- Failures are indistinguishable to the peer: a wrong key, a stale hello, and a
  malformed frame all end the session the same way.

The format is pinned by golden vectors in `format_test.go`, and the node half in
the agent repo carries the **same** table. That is how cross-repo conformance is
proven without a live node: a one-byte change on either side fails one of the
two suites.

This is deliberately **not** an anti-probing construction (no REALITY-style
borrowed handshake). The node presents its own certificate, so an active prober
sees a real TLS server that does not complete the handshake without the key. At
the enterprise/campus IPS tier this is the right trade: the traffic is
indistinguishable from HTTPS to a VPN provider, and the AWG rung remains the
primary defence.

### Lifecycle and routing

The bridge is not a privilege boundary — it binds a loopback port and dials out
— but the daemon owns its lifetime because the tunnel's lifecycle is the
daemon's: an app-restarted client would orphan it, and only the daemon can route
around the tunnel.

There is no external binary and no configuration document, so nothing to sign,
ship, or fingerprint. The spec carries credentials instead — pins, PSK, client
id — and the PSK never reaches a log or the disk. It travels over the daemon's
local socket, which is the same channel the tunnel's own private key already
travels on.

The bridge binds its loopback socket before `up` returns, so the tunnel never
meets a refused port; the TLS session behind it comes up on its own and the
tunnel's handshake timer covers the wait. A session that drops reconnects with
backoff for as long as the tunnel lives, so no client involvement is needed.

Two routing facts make or break the egress, both handled in
`internal/tunnel/transport_linux.go`:

- The bridge's own packets must never enter the tunnel they carry, so a host
  route for the real server is pinned through the physical gateway **before**
  `wg-quick up`.
- `wg-quick`'s strict-mode policy rules steer *unmarked* packets — which is
  every packet the bridge's dialer sends — into its own routing table before the
  main one. The same pin is therefore installed in every table an
  `not fwmark … table N` rule selects, parsed from `ip rule show` after
  `wg-quick up` rather than predicted from the interface name.

Stream transport is Linux-only for now; Windows and macOS reject the spec
(`bad_config`) rather than silently ignoring it, since a silently ignored spec
would leave the tunnel on a dead loopback endpoint. It is not combined with
the AmneziaWG directives — one rung at a time.

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

- The client sends the same validated wg-quick text it sends everywhere.
  `config.Validate` still rejects `PreUp`/`PostUp`/`PreDown`/`PostDown`/
  `SaveConfig`, so the client cannot turn `up` into root code execution.
- `[Interface] Address` and `DNS` are **not** forwarded to the device: it
  rejects unknown keys, and it has no concept of either. The backend applies
  them itself, which is also what lets one client config drive all three
  platforms.
- Privileged tools (`ifconfig`, `route`, `netstat`) are resolved from a fixed
  `/sbin:/usr/sbin:/bin:/usr/bin` list, never `PATH` — the daemon runs as root,
  so a caller-influenced `PATH` would otherwise execute as root.
- The config directory must be root-owned and inaccessible beyond its owner, or
  the daemon refuses to start: a user-writable config directory would let a
  standard account replace the config the daemon later reads.
- The socket is `root:<group>` 0660 (empty group ⇒ `root:root` 0600).

### Honest status: this is not proven on hardware

Everything in the macOS backend is behind `//go:build darwin`, so the Linux and
Windows runners **cannot execute it**. What CI does verify:

- it compiles for `darwin/amd64` and `darwin/arm64`;
- `go vet` type-checks the darwin-tagged files **and their tests**;
- `golangci-lint` runs with `GOOS=darwin`;
- the UAPI translation layer (`internal/tunnel/uapi.go`) and the client's
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

- Linux: `/var/log/boltmesh/boltmeshd.log`
- Windows: `%ProgramData%\BoltMesh\logs\boltmeshd.log`
- macOS: `/var/log/boltmesh/boltmeshd.log` (plus `/var/log/boltmesh/launchd.log`
  for anything launchd itself reports)
