# End-to-end harness

This proves the one thing unit tests cannot: that the real desktop app — Linux
**or** Windows — driving the real privileged `boltmeshd`, brings a real
WireGuard tunnel up to a real serving node and moves packets across it, on
every rung the node serves.

Both ends are real. The client half is the app, built from source and run under
`integration_test/app_e2e.dart`; the node half is a **real running node** —
one you already have, registered against the real API, heartbeating, and serving
its own ingress. There is no stub control plane and no second copy of the agent:
a node that has not registered has no WireGuard public key, cannot be bound to a
device, and advertises no transport at all, so a fixture standing in for one
would prove less, not more.

```text
  this host                          real node (test1, test2, ...)
  ┌────────────────────────┐          ┌────────────────────────────┐
  │ Flutter app            │          │ agentd                     │
  │   ↓ helper socket/pipe │  TLS 1.3 │   wg0 (kernel wgctrl)      │
  │ boltmeshd              │─────────▶│   stream ingress :443      │
  │   wg-quick → boltmesh0 │          │                            │
  └───────────┬────────────┘          └─────────────┬──────────────┘
              │        real API, in between         │
              └─── device create, config, PSK ──────┘
```

The API is in the middle because that is where it sits in production. It binds
the device to a serving node, hands the client the node's public key, the node's
tunnel address, and the stream credential, and it withholds the stream rung
entirely until the node has reported a TLS pin on its heartbeat. So the credential
this harness uses is one a live listener reported, and its presence is itself
evidence that the node is up.

## Running it

One program, `integration_test/app_e2e.dart`, runs on both platforms; only the
runner differs, because what surrounds it — the helper's transport, the display,
the keyring — is the platform's business, not the app's. Each platform below is
two steps: privileged helper install, then the unprivileged run.

### Linux

Needs `flutter`, `Xvfb`, `gnome-keyring-daemon`, `secret-tool`, `python3`, and a
Go toolchain, plus `sudo` for the one privileged step: installing the helper.

```sh
sudo tool/e2e/install_boltmeshd.sh

tool/e2e/run_linux_app.sh
```

`install_boltmeshd.sh` is the only part that runs as root: it builds
`boltmeshd` from source and installs it, so the run always exercises the
current helper code. `run_linux_app.sh` runs entirely as the normal user (it
refuses root and `sudo`, because `flutter` itself refuses root). Both need
this user enrolled in the `boltmesh` group.

### Windows

Needs `flutter` with the Windows desktop target, a Go toolchain, and `python`,
plus elevation for the one privileged step: installing the helper.

```powershell
pwsh -File tool/e2e/install_boltmeshd.ps1      # elevated

pwsh -File tool/e2e/run_windows_app.ps1        # unprivileged
```

`install_boltmeshd.ps1` builds `boltmeshd.exe` from source, stages the four
files the helper loads from beside itself (`boltmeshd.exe`, `wintun.dll`,
`wireguard_svc.exe`, `wireguard.dll`), and runs `boltmeshd.exe -install`, which
registers the service and starts it. It must be that service: the runner's
`com.boltmesh/helper` channel authenticates the pipe's server process against
the one the SCM reports for the `boltmeshd` service, so a helper started by
hand (`-console`) is refused by the app even though its pipe exists. Logs:
`%ProgramData%\BoltMesh\logs\boltmeshd.log`.

`run_windows_app.ps1` runs the app unprivileged, like the Linux twin does.
Because a named pipe's DACL grants access to Interactive Users, a process whose
token lacks that group — one started over SSH, by a service, or by an ordinary
scheduled task — cannot open the pipe at all. When the script is not already in
the interactive session it therefore re-executes itself there through a
limited-privilege scheduled task, streams the log, and reports the exit code.
The stream is a PowerShell transcript, which flushes in chunks, so it can sit
unchanged for minutes while the run is fine — which reads exactly like a hang.
The relaunching run therefore prints a heartbeat naming the newest screenshot,
and the screenshots are the honest clock: they land on disk at each stage, well
before the transcript catches up. The full transcript is left at
`%TEMP%\boltmesh-windows-app-e2e\run.log`. That is also why it never elevates
the app: the point of the run is that the unprivileged GUI talks to the
privileged helper.

Each platform stops before a run it cannot usefully do: a stopped helper on
Windows is one the app cannot reach (there is no socket activation), and a
Linux run without the socket is the same.

### Both

Credentials are read from the environment when it carries both halves, and
otherwise from the gitignored `.env.e2e` at the repo root (override the path
with `BOLTMESH_E2E_CREDS_FILE`) — so a bare run needs no export first. They
are never passed as a flag: the process list is world-readable, and a password
there outlives the run. The relaunched Windows run receives them through a file
in the invoking user's own work directory, which is the same trade.

`.env` supplies the API URL as `--dart-define-from-file`, the same way `make run`
does; point it elsewhere with `ENV_FILE=staging.env` on Linux, `-EnvFile` on
Windows.

## Where the two hosts differ

The four tests above are identical on both platforms. What differs is the host,
and it is all collected in one `_Host` seam at the bottom of
`integration_test/app_e2e.dart`:

| | Linux | Windows |
| --- | --- | --- |
| helper transport | Unix socket `--socket /run/boltmesh/boltmeshd.sock` | named pipe `--pipe \\.\pipe\boltmesh\boltmeshd` |
| "the tunnel exists" | `ip link show boltmesh0` | the adapter table (`Get-NetAdapter -Name boltmesh0`) |
| the data plane's counters | `wg show boltmesh0 transfer` | the daemon's own `status`, which is what a userspace AmneziaWG device gets instead of a kernel view |
| in-tunnel ping | `ping -c 3 -W 3`, `0% packet loss` | `ping -n 3 -w 3000`, `(0% loss)` |
| screenshots | ImageMagick `import` (the X display the app is on) | `tool/e2e/screenshot.ps1`, the primary screen |
| a fresh session | a scratch keyring, isolated from the operator's | the app's `flutter_secure_storage.dat` removed |
| Python interpreter | `python3` | `python` (`BOLTMESH_E2E_PYTHON` overrides both) |

The "tunnel exists" row is the one worth reading twice. The obfuscated rung on
Windows runs an in-process AmneziaWG device over a Wintun adapter and registers
no `boltmesh0` *service*, so a service probe would read "no tunnel" mid-ladder;
the adapter is named `boltmesh0` on every rung, which is what makes it the
Windows analogue of `ip link show`.

## The four tests

Four tests, in order, each building on the last. They share one `flutter test`
process and one store, so the session and the device identity carry across them
— which is also what puts the restore path inside what is covered.

1. **signs in** — types the real credentials into the real form and reaches the
   VPN tabs. A stored session short-circuits this and says so; each runner
   starts from a fresh store (a scratch keyring on Linux, no secure-storage
   file on Windows), so a scripted run does drive the form.
2. **walks the transport ladder native, awg, stream** — pins the controller to
   each rung in turn through its `debugForceRung` seam (a walk the health policy
   would only take on a blocked network, which a lab run cannot fabricate). The
   first rung comes up through the Home power control; the others are restarts
   through the controller, reusing the bound session rather than spending the
   backend's shared write budget on a disconnect+connect pair per rung. For each
   rung it waits for `connected`, checks the UI agrees (the header names the
   server, the button reads Disconnect), and asserts on bytes: the app's own
   received counter, the kernel's `wg` counters when the kernel owns the data
   plane, and an in-tunnel ping to that rung's own node address with no loss.
   Finishes with one power-control disconnect that must leave `boltmesh0` gone.
3. **switches server** — connects, then picks a *different* server in the
   Regions tab and asserts the live dial moved to it. The wait is on the
   controller's own arc, which only reaches `connected` again once the daemon
   reports a new handshake; the run then pings the *new* node's tunnel address,
   so a switch that reported success over a dead peer fails here rather than
   quietly leaving the rest of the run measuring the old tunnel. With only one
   server on offer there is nothing to switch *to*, so it exercises Quick
   Connect instead and says which path it took.
4. **logs out** — connects first, so logout has a live tunnel to tear down, then
   signs out and asserts the login screen is back and the interface is gone.

### Clearing devices first

The subscription caps how many devices can be active, and a run that fails
part-way leaves its row behind: the interface is gone, the row is not. The *next*
run then cannot provision and reports a device limit that the run reporting it
never caused — a bad way to fail, because the run that broke is long gone.

So both runner scripts delete the account's devices before the app starts, and
`tool/e2e/client.py` can do it on its own:

```sh
python3 tool/e2e/client.py --clear-devices \
  --api-base "$API_BASE_URL" \
  --api-user "$BOLTMESH_E2E_API_USER" --api-password "$BOLTMESH_E2E_API_PASSWORD"

# see what it would remove, delete nothing
python3 tool/e2e/client.py --clear-devices --dry-run ...
```

It disconnects each row before deleting it (the backend refuses to drop a row
with a live tunnel bound), names every row as it goes, and keeps going past one
that fails — a half-cleared account is the exact state this exists to prevent.
`BOLTMESH_E2E_KEEP_DEVICES=1` skips it and `BOLTMESH_E2E_DRY_RUN=1` lists
without deleting.

**This is destructive.** It is a lab harness aimed at a test account; nothing
here should be pointed at an account whose devices matter.

### Two failure modes worth knowing

Both cost real time here, so both are guarded in the test rather than left as
folklore:

- **The Connect button can be disabled, and tapping it then does nothing.** It
  hard-disables while the backend-health poll reports `unreachable`, and on a
  headless box that is a real possibility: `connectivity_plus` reads
  NetworkManager over D-Bus, so a session without one reports no link. The tap
  hit-tests cleanly, so nothing complains and the run would burn the whole
  connect timeout blaming the transport. The test waits for the button to be
  enabled and fails with that named.
- **A tunnel left up poisons the next test.** This box *is* the client, so each
  test tears its own tunnel down, and the `addTearDown` net goes to the helper's
  socket rather than the app's controller: by the time tear-down runs, the widget
  tree and its `ProviderContainer` are gone, so a controller-based net throws
  "container already disposed" and accomplishes nothing. The net does not gate on
  an interface-name probe, which a host may not be able to read, so a failed run
  tears down exactly when it must.

On Linux the app runs on a virtual display and an isolated keyring, which the
script sets up because they are lab facts rather than app behaviour:

| | Why |
| --- | --- |
| `Xvfb` on `:99` | a headless box has no display; `BOLTMESH_E2E_DISPLAY` overrides |
| `XDG_DATA_HOME` + `gnome-keyring-daemon --unlock` | the app persists its session and device keys through libsecret, which needs an unlocked collection. Isolating it means a lab run cannot read or rewrite the operator's real login keyring, and it can never leave one locked |

Session restore is exercised rather than avoided: a rerun against the same work
directory comes up already signed in, and the test says so and skips the form.
The device identity lives in that keyring too, so it is reused between runs,
which the node's peer table requires — it is built from the public half the
backend stored.

`BOLTMESH_E2E_SHOT_DIR` (set by the script) makes the test screenshot the real
window at each stage. It is best effort: on Linux that is ImageMagick's `import`
reading the X display, on Windows `tool/e2e/screenshot.ps1` reading the primary
screen. No tool, no pictures, still a valid run.

## Self-tests

`test_harness.py` covers the harness's own logic and needs no root, no node, and
no display:

```sh
python3 tool/e2e/test_harness.py
```

A fixture that reports PASS while exercising nothing is worse than no fixture, so
these cover the helper protocol `client.py` speaks — over the unix socket on
Linux and the named pipe on Windows, where a `ctypes` `CreateNamedPipe` server
stands in for the daemon — the device clearing the runners do before the app
starts, and one static check on the Windows runner scripts: a Python-style
docstring there is not a docstring but a bare string expression, whose value
joins the enclosing function's output and quietly corrupts what it returns.

## What it does not prove

A pass rules out implementation defects between the two halves. It does not test
real NAT, a real enterprise/campus IPS, or any evasion property, and it says
nothing about a node that is not currently serving. This is deliberately not an
anti-probing construction — see `boltmeshd/README.md`.
