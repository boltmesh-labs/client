# boltmeshd

Privileged Linux helper for the BoltMesh client.

The Flutter app runs unprivileged. It never calls `sudo`, `wg`, or `wg-quick`,
and never reads the WireGuard device directly. `boltmeshd` owns the interface
lifecycle and all privileged reads, and serves them to the app over a Unix
socket.

## Why

The `wireguard_flutter_plus` Linux backend shells out to `sudo wg` and
`sudo wg-quick` from the GUI process. That means password prompts, TTY
dependence, and a privileged surface inside the UI process. `boltmeshd`
replaces all of it with a single root daemon and a narrow, validated protocol.

## Protocol

Newline-delimited JSON over `/run/boltmesh/boltmeshd.sock`, one request per
line, one response per line.

```json
{"v":1,"id":"1","op":"up","config":"[Interface]\n..."}
{"v":1,"id":"1","ok":true,"status":{"interface":"boltmesh0","up":true,"stage":"connected","lastHandshake":1718000000,"rxBytes":123,"txBytes":456}}
```

| op | meaning |
| --- | --- |
| `ping` | liveness + version check; returns status |
| `status` | current stage, newest handshake, summed rx/tx, live peer |
| `up` | validate `config`, persist it root-only, `wg-quick up` |
| `down` | idempotent teardown |

Error codes: `bad_request`, `bad_config`, `unavailable`, `internal`.

Stages: `connected`, `connecting` (an `up` is in flight), `disconnected`.
A zero `lastHandshake` or empty counters mean *unknown*, never *dead* — the
app's health policy decides.

## Security model

- The single `up` argument is a wg-quick config. It is validated before any
  privilege is spent: one `[Interface]` and at least one `[Peer]`, parsed
  key material, size cap, and a hard reject of the `PreUp`/`PostUp`/
  `PreDown`/`PostDown`/`SaveConfig` hooks (wg-quick runs those as root).
- The interface name and config path are fixed by the daemon; the client
  cannot name an interface or path.
- No shell with client data: `exec.Command` with explicit args, and device
  reads go through `wgctrl`/netlink.
- The socket is `0660 root:boltmesh`; only members of the `boltmesh` group
  can connect. The daemon runs as root but with `NoNewPrivileges`,
  `ProtectSystem=full`, `ProtectHome`, `PrivateTmp`, restricted address
  families, and no new namespaces.

## Build

```sh
make build        # amd64 + arm64 to bin/
make test         # go test ./... -v -count=1
make all          # clean + format + lint + vet + test + build + checksums
```

## Install (from the deb/rpm)

The packages install the binary to `/usr/libexec/boltmesh/boltmeshd`, the
units to `/usr/lib/systemd/system/`, create the `boltmesh` group, add the
desktop user to it, and enable the socket:

```sh
sudo systemctl enable --now boltmeshd.socket
```

They also drop a NetworkManager configuration at
`/etc/NetworkManager/conf.d/99-boltmesh-unmanaged.conf` that marks
`boltmesh0` unmanaged, so NetworkManager does not assume the externally
created link and GNOME does not report an activation failure when the tunnel
is torn down.

Log out and back in so the group membership applies. Verify:

```sh
printf '{"v":1,"id":"1","op":"ping"}\n' | socat - UNIX-CONNECT:/run/boltmesh/boltmeshd.sock
```

## Run from source (development)

```sh
sudo groupadd -f boltmesh
sudo usermod -aG boltmesh "$USER"   # re-login afterwards

make build
sudo ./bin/boltmeshd-linux-amd64 --socket=/run/boltmesh/boltmeshd.sock
```

`wireguard-tools` must be installed for `wg-quick`.

On Fedora/GNOME hosts, also install the NetworkManager drop-in so tearing the
tunnel down does not raise a spurious "Connection failed" notification:

```sh
sudo install -Dm644 deploy/99-boltmesh-unmanaged.conf /etc/NetworkManager/conf.d/99-boltmesh-unmanaged.conf
sudo nmcli general reload conf
```
