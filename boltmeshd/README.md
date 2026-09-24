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
| `ping` | liveness + version check; returns status and the daemon's `caps` |
| `status` | current stage, newest handshake, summed rx/tx, live peer |
| `up` | validate `config`, persist it privileged, start the tunnel |
| `down` | idempotent teardown |

Every request must carry `v`, a well-formed `id`, and a known `op`. The
daemon enforces the envelope before any privileged work:

- **`id`** is required, 1–64 characters from `[A-Za-z0-9._:-]`. It is echoed
  verbatim on the response; an id the daemon would reject is never echoed.
- **`config` is only valid for `up`**, where it is required. A `config` on
  `ping`/`status`/`down` is rejected.
- **Unknown fields and trailing tokens are rejected**, so one line frames
  exactly one request.
- **Response correlation is strict**: the client checks the echoed `id`, the
  `v`, and that exactly one of `error`/`status` is present.

Error codes: `bad_request`, `bad_config`, `unavailable`, `internal`.
`bad_request` covers envelope violations; `bad_config` is reserved for config
content that fails validation.

Each complete privileged request has a 40-second daemon budget: up to 30
seconds for the command sequence plus five seconds for bounded failure cleanup,
with the remaining margin for transport and scheduling. The normal client
backstop is 45 seconds. A client may use a shorter cancellation budget (the
stop path uses 3 seconds); closing its socket or named pipe cancels the request
context. The transport also has a 45-second idle read deadline, a 5-second
response write deadline, and a 32-connection active limit; excess connections
are closed immediately. If the per-request budget expires, its connection is
closed rather than reused. Linux commands run in their own process group with a
bounded wait for output pipes, so cancellation cannot leave a `wg-quick`
descendant holding the privileged operation. A bounded retry waits for the
manager's lifecycle gate rather than issuing a concurrent teardown.

Stages: `connected`, `connecting` (an `up` is in flight), `disconnected`.
A zero `lastHandshake` or empty counters mean *unknown*, never *dead* — the
app's health policy decides.

### Capability negotiation

Negotiation is optional and informational. A client may send a `caps` array
(≤16 short lowercase tokens) of the capabilities it understands, and the
daemon advertises its own list on the `ping` response:

```json
{"v":1,"id":"1","op":"ping"}
{"v":1,"id":"1","ok":true,"caps":["strict-validation","caps"],"status":{...}}
```

The daemon always enforces request validation regardless of the tokens
present; `caps` lets the two sides learn about each other without a version
bump, and its absence (an older or simpler peer) is tolerated. Current tokens:
`strict-validation` (hardened request envelope) and `caps` (advertises
capabilities). `status` keeps its line lean and carries no `caps`.

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
  Administrators and Interactive Users. During elevated installation the
  machine-wide config and log directories are verified, made SYSTEM-owned, and
  given a protected SYSTEM + Administrators DACL; reparse points are rejected.
  Config and log files are replaced through fresh exclusive temporary files
  whose owner and DACL are set before any bytes are written, so a pre-existing
  file or open handle cannot redirect or observe a new secret.
- **Linux**: the socket is `0660 root:boltmesh`; only members of the
  `boltmesh` group can connect. The package's root-only
  `/usr/libexec/boltmesh/boltmesh-enroll-user` command is the explicit enrollment
  boundary; the Flutter app never elevates itself or changes group membership.
  The daemon runs as root with `NoNewPrivileges`, `ProtectSystem=full`,
  `ProtectHome`, `PrivateTmp`, restricted address families, and no new
  namespaces.

## Logging

The daemon logs twice, with independent levels:

- **stdout** — human-readable `key=value` records at `LOG_LEVEL` (default
  `INFO`). This is what journald captures on Linux and what `-console` prints
  on Windows.
- **a persistent JSON-lines file** — one JSON object per line, only
  `WARN` and above, so it records failures without duplicating the access
  log. The file rotates at 5 MiB, keeping 5 backups (`boltmeshd.log`,
  `boltmeshd.log.1` … `.5`), for a ~25 MiB ceiling.

| OS | Path |
| --- | --- |
| Linux | `/var/log/boltmesh/boltmeshd.log` (systemd `LogsDirectory=boltmesh`, mode `0750`) |
| Windows | `%ProgramData%\BoltMesh\logs\boltmeshd.log` (fresh SYSTEM-owned file; protected DACL: SYSTEM + Administrators) |

Override the path with `-log-file` or `BOLTMESHD_LOG_FILE`; an empty value
disables file logging. A path that cannot be created or opened is reported and
the daemon continues with stdout only — logging never blocks startup.

Failure records carry the operation, the protocol error code and the error
text (e.g. `{"level":"WARN","msg":"tunnel operation failed","op":"up","code":"unavailable","error":"…"}`).
The client's wg-quick config — which holds the WireGuard private key — is never
logged.

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

The Windows arm64 binary is a standalone cross-build for manual use. The
BoltMesh Windows client packages the x64 helper only (the bundled
`wireguard_flutter_plus` plugin provides amd64 tunnel/wireguard DLLs), and
`windows/packaging/stage_boltmeshd.ps1` refuses a non-x64 bundle.

The Windows manager and its tests are build-tagged, so `go test ./...` on
Linux covers the shared and Linux code; CI runs the Windows-tagged tests on a
Windows runner (and `GOOS=windows go vet` on Linux).

## Linux: install (from the deb/rpm)

The packages install the binary to `/usr/libexec/boltmesh/boltmeshd`, the
units to `/usr/lib/systemd/system/`, create the `boltmesh` group, and enable
the socket. During post-install, BoltMesh first uses a validated elevation
hint (`PKEXEC_UID`/`SUDO_UID` or a resolved legacy `SUDO_USER`) to identify the
installing account. Without such a hint, it enrolls a unique active graphical
session when logind can identify one. This works for sudo, root-shell,
PackageKit, and polkit-launched package managers without granting the group to
every local account. PackageKit has no portable transaction-to-caller identity,
so if logind is unavailable or more than one desktop user is active, the
install leaves enrollment explicit rather than guessing. Run the root command
for the login that should control the tunnel:

```sh
sudo /usr/libexec/boltmesh/boltmesh-enroll-user --uid "$(id -u alice)"
# Or, from a desktop policy agent:
pkexec /usr/libexec/boltmesh/boltmesh-enroll-user --uid "$(id -u alice)"
sudo systemctl enable --now boltmeshd.socket
```

An attempted enrollment that fails is reported and fails the post-install
rather than being silently ignored. The enrollment command is separate from
the Flutter app, so the app never needs elevation. To revoke access later, use
`sudo gpasswd -d alice boltmesh`; do not remove the shared group itself.

They also drop a NetworkManager configuration at
`/etc/NetworkManager/conf.d/99-boltmesh-unmanaged.conf` that marks
`boltmesh0` unmanaged, so NetworkManager does not assume the externally
created link and GNOME does not report an activation failure when the tunnel
is torn down.

Stopping the service always tears down the fixed `boltmesh0` interface before
the helper exits. The daemon waits for active requests, calls `Manager.Down`
with a fresh bounded context, and the unit repeats that cleanup in
`ExecStopPost` for a process that exits unexpectedly. The unit uses the
synchronous default `SIGTERM`/`KillMode=mixed` path rather than an asynchronous
`ExecStop` signal wrapper. The service owns
`/run/boltmesh` and preserves it through the stop sequence; the socket unit
removes only its socket node. The deb/rpm uninstall scripts stop the service
before the socket, retry `boltmeshd --cleanup`, and remove the runtime directory
only after teardown succeeds. If cleanup fails, package removal stops before
deleting the helper so it can be retried.

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
boltmeshd.exe -uninstall   # stop + delete the tunnel and helper services
```

Uninstall first quiesces the daemon so it cannot recreate the tunnel, then
stops and removes the `boltmesh0` service and its persisted configuration
(including the private key). It waits for the daemon to reach `SERVICE_STOPPED`
and for both service registrations to disappear before it returns. The
`boltmeshd` service is auto-start. Installation also configures the Service
Control Manager to restart the helper after 5, 15, and 60 seconds if it fails;
the recovery count resets after 24 hours of healthy service. The GUI needs no
elevation: it talks to the named pipe and the daemon creates/starts the
`boltmesh0` tunnel service on demand. `-console` runs the daemon in the
foreground for development.

The config lives under `%ProgramData%\BoltMesh`. Elevated `-install` verifies
and hardens that directory before registering the service; the daemon repeats
the check before every `up`. Reparse points are rejected, the directory is
SYSTEM-owned, and each config update writes a fresh exclusive temporary file
with its owner and protected SYSTEM + Administrators DACL applied before the
private key is written, then atomically renames it into place. The persistent
log is prepared the same way before the logging package opens it.

## Linux: run from source (development)

```sh
sudo groupadd -f boltmesh
sudo usermod -aG boltmesh "$USER"   # re-login afterwards

make build-amd64
sudo ./bin/boltmeshd-linux-amd64 --socket=/run/boltmesh/boltmeshd.sock
```

Do not run a helper from this user-writable checkout with `sudo`; use the
root-owned packaged command for production enrollment. Log out and back in
after enrollment so the new supplementary group is present in the desktop
process.

`wireguard-tools` must be installed for `wg-quick`.

On Fedora/GNOME hosts, also install the NetworkManager drop-in so tearing the
tunnel down does not raise a spurious "Connection failed" notification:

```sh
sudo install -Dm644 deploy/99-boltmesh-unmanaged.conf /etc/NetworkManager/conf.d/99-boltmesh-unmanaged.conf
sudo nmcli general reload conf
```

## Windows: run from source (development)

Build the Flutter Windows bundle first. This is important because
`wireguard_svc.exe`, `wireguard.dll`, and Wintun are supplied by the
`wireguard_flutter_plus` plugin; `boltmeshd` deliberately does not download or
copy those privileged binaries itself.

```powershell
flutter build windows --debug
Push-Location boltmeshd
go build -o ..\build\windows\x64\runner\Debug\boltmeshd.exe .\cmd\boltmeshd
Pop-Location
# Elevated once, to register the service; then it runs as LocalSystem.
build\windows\x64\runner\Debug\boltmeshd.exe -install
```

Run the app from that same `build\windows\x64\runner\Debug` directory. The
helper validates that `wireguard_svc.exe` is present before touching the
tunnel; if it is missing, rebuild the Flutter bundle rather than registering a
standalone helper from `boltmeshd\bin`.

For a quick foreground test without installing a service, run it elevated with
`-console`; the GUI can then talk to the pipe while it is running.
