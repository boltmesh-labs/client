# boltmeshd

Privileged helper for the BoltMesh client, on Linux and Windows.

The Flutter app runs unprivileged. It never calls `sudo`, `wg`, `wg-quick`,
never creates or elevates a Windows service, and never reads the WireGuard
device directly. `boltmeshd` owns the tunnel lifecycle and all privileged
reads, and serves them to the app over a local transport:

| OS | Backend | Transport |
| --- | --- | --- |
| Linux | `wg-quick` + `wgctrl` | Unix socket `/run/boltmesh/boltmeshd.sock` |
| Windows | WireGuard-for-Windows tunnel service + `wireguard.dll` | Named pipe `\\.\pipe\boltmesh\boltmeshd` |

## Why

- **Linux**: the `wireguard_flutter_plus` backend shells out to `sudo wg` and
  `sudo wg-quick` from the GUI process (password prompts, TTY dependence, a
  privileged surface in the UI process).
- **Windows**: the plugin's backend creates and starts a LocalSystem service
  running `wireguard_svc.exe`, which requires the whole GUI to be elevated via
  a `requireAdministrator` manifest.

`boltmeshd` replaces both with a single privileged daemon and a narrow,
validated protocol.

## Protocol

Newline-delimited JSON, one request per line, one response per line, over the
OS transport above.

```json
{"v":1,"id":"1","op":"up","config":"[Interface]\n..."}
{"v":1,"id":"1","ok":true,"status":{"interface":"boltmesh0","up":true,"stage":"connected","lastHandshake":1718000000,"rxBytes":123,"txBytes":456}}
```

| op | meaning |
| --- | --- |
| `ping` | liveness + version check; returns status |
| `status` | current stage, newest handshake, summed rx/tx, live peer |
| `up` | validate `config`, persist it privileged, start the tunnel |
| `down` | idempotent teardown |

Error codes: `bad_request`, `bad_config`, `unavailable`, `internal`.

Stages: `connected`, `connecting` (an `up` is in flight), `disconnected`.
A zero `lastHandshake` or empty counters mean *unknown*, never *dead* — the
app's health policy decides.

## Security model

- The single `up` argument is a wg-quick config. It is validated before any
  privilege is spent: one `[Interface]` and at least one `[Peer]`, parsed key
  material, size cap, and a hard reject of the `PreUp`/`PostUp`/`PreDown`/
  `PostDown`/`SaveConfig` hooks.
- The interface name and config path are fixed by the daemon; the client
  cannot name an interface or path.
- No shell with client data: `exec.Command` with explicit args on Linux; the
  Windows manager talks to the SCM through `x/sys/windows/svc/mgr`.
- **Windows**: the tunnel service's binary is fixed by the daemon (the
  `wireguard_svc.exe` installed beside it), never taken from the client. A
  client that could name the service binary would turn a LocalSystem service
  into arbitrary code execution. The named pipe is ACL'd to SYSTEM,
  Administrators and Interactive Users, and the persisted wg-quick config
  directory/file to SYSTEM and Administrators only (a protected DACL, so
  ProgramData inheritance cannot widen it).
- **Linux**: the socket is `0660 root:boltmesh`; only members of the
  `boltmesh` group can connect. The daemon runs as root with
  `NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome`, `PrivateTmp`,
  restricted address families, and no new namespaces.

## Build

```sh
make build        # Linux amd64/arm64 + Windows amd64/arm64 to bin/
make test         # go test ./... -v -count=1
make all          # clean + format + lint + vet + test + build + checksums
```

`bin/` is gitignored and never committed: the privileged helper is built
locally (`make build`) and by the packaging hooks (`boltmeshd/packaging/stage.sh`
for deb/rpm, `windows/packaging/stage_boltmeshd.ps1` for the Inno installer), so
a checked-in binary cannot drift from the reviewed source. `make checksums`
writes `bin/checksums.txt` for a local build.

The Windows manager and its tests are build-tagged, so `go test ./...` on
Linux covers the shared and Linux code; CI runs the Windows-tagged tests on a
Windows runner (and `GOOS=windows go vet` on Linux).

## Linux: install (from the deb/rpm)

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

## Windows: install (from the Inno installer)

The installer places `boltmeshd.exe` in `%ProgramFiles%\BoltMesh` next to the
plugin-bundled `wireguard_svc.exe` and `wireguard.dll`, then runs:

```powershell
boltmeshd.exe -install     # create + start the boltmeshd service (LocalSystem)
```

and on uninstall:

```powershell
boltmeshd.exe -uninstall   # stop + delete the service
```

The `boltmeshd` service is auto-start. The GUI needs no elevation: it talks to
the named pipe and the daemon creates/starts the `boltmesh0` tunnel service on
demand. `-console` runs the daemon in the foreground for development.

The config lives under `%ProgramData%\BoltMesh`. The daemon tightens that
directory and the config file to a protected DACL granting only SYSTEM and
Administrators on every `up` (`internal/tunnel/security_windows.go`), so
ProgramData's default `BUILTIN\Users` inheritance cannot expose the WireGuard
private key. `os.Chmod` is a no-op protection on Windows, so this is the real
control.

## Linux: run from source (development)

```sh
sudo groupadd -f boltmesh
sudo usermod -aG boltmesh "$USER"   # re-login afterwards

make build-amd64
sudo ./bin/boltmeshd-linux-amd64 --socket=/run/boltmesh/boltmeshd.sock
```

`wireguard-tools` must be installed for `wg-quick`.

On Fedora/GNOME hosts, also install the NetworkManager drop-in so tearing the
tunnel down does not raise a spurious "Connection failed" notification:

```sh
sudo install -Dm644 deploy/99-boltmesh-unmanaged.conf /etc/NetworkManager/conf.d/99-boltmesh-unmanaged.conf
sudo nmcli general reload conf
```

## Windows: run from source (development)

```powershell
make build-windows-amd64
# Elevated once, to register the service; then it runs as LocalSystem.
.\bin\boltmeshd-windows-amd64.exe -install
```

For a quick foreground test without installing a service, run it elevated with
`-console`; the GUI can then talk to the pipe while it is running.
