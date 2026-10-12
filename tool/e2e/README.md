# End-to-end harness

This proves the one thing unit tests cannot: that the real app — on Linux,
Windows **or** Android — brings a real WireGuard tunnel up to a real serving
node and moves packets across it, on every rung the node serves.

The desktop hosts do it by driving the real privileged `boltmeshd`; Android has
no helper and runs the same tunnel in-process over its `VpnService`, so where a
desktop run proves the app-to-daemon boundary, an Android run proves the
on-device path end to end.

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

One program, `integration_test/app_e2e.dart`, runs on every platform; only the
runner differs, because what surrounds it — the helper's transport, the display,
the keyring, the device's VPN consent — is the platform's business, not the
app's. On the desktop hosts each platform below is two steps: privileged helper
install, then the unprivileged run. Android is one step, because the app owns
the tunnel itself and the runner sets up the device state it needs.

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

### Android

Needs `flutter`, `adb`, `python3`, an attached device or emulator, and an
account on a serving node — nothing privileged, because the app owns the tunnel
in-process rather than through a helper.

```sh
tool/e2e/run_android_app.sh
```

The runner picks the sole attached device (or `BOLTMESH_E2E_ANDROID_SERIAL` /
`ANDROID_SERIAL` when there is more than one), then does the device setup the
test cannot do for itself:

- **Grants VPN consent.** `VpnService.prepare` pops a system dialog the first
  time an app wants a TUN, and nothing inside the test can tap it, so the run
  would hang on the dialog and read as a dead transport. The runner sets the
  `ACTIVATE_VPN` appop up front, which makes `prepare` return null.
- **Clears app data** for a fresh sign-in and device identity
  (`BOLTMESH_E2E_KEEP_SESSION=1` keeps the store to exercise the restore path).
- **Clears the account's devices**, exactly as the desktop runners do.

The app is installed, the appop is granted, and then `flutter test` rebuilds
and reinstalls the same package: a reinstall preserves both the appop and the
cleared data.

The credentials reach the app as `--dart-define-from-file`, not through the
environment — the test code runs *on the device*, where the host environment
does not exist. That embeds them in the debug APK on the emulator, which is the
same trade the Windows relaunch makes with its work-directory file.

### Credentials (every platform)

Credentials are read from the environment when it carries both halves, and
otherwise from the gitignored `.env.e2e` at the repo root (override the path
with `BOLTMESH_E2E_CREDS_FILE`) — so a bare run needs no export first. They
are never passed as a flag: the process list is world-readable, and a password
there outlives the run. The relaunched Windows run receives them through a file
in the invoking user's own work directory, which is the same trade; the Android
run passes them to the app with `--dart-define-from-file`.

`.env` supplies the API URL as `--dart-define-from-file`, the same way `make run`
does; point it elsewhere with `ENV_FILE=staging.env` on Linux and Android,
`-EnvFile` on Windows.

## Where the hosts differ

The four tests above are identical on every platform. What differs is the host,
and it is all collected in one `_Host` seam at the bottom of
`integration_test/app_e2e.dart`:

| | Linux | Windows | Android |
| --- | --- | --- | --- |
| helper transport | Unix socket `--socket /run/boltmesh/boltmeshd.sock` | named pipe `--pipe \\.\pipe\boltmesh\boltmeshd` | none — the app owns the `VpnService` TUN in-process |
| "the tunnel exists" | `ip link show boltmesh0` | the adapter table (`Get-NetAdapter -Name boltmesh0`) | `NetworkInterface.list()` finds the app's `tun0` |
| the data plane's counters | `wg show boltmesh0 transfer` | the daemon's own `status`, which is what a userspace AmneziaWG device gets instead of a kernel view | none readable — the app's counters stand, `kernelReceivedBytes` returns null |
| in-tunnel ping | `ping -c 3 -W 3`, `0% packet loss` | `ping -n 3 -w 3000`, `(0% loss)` | `/system/bin/ping -c 3 -W 3`, `0% packet loss` |
| screenshots | ImageMagick `import` (the X display the app is on) | `tool/e2e/screenshot.ps1`, the primary screen | none (the runner can `adb exec-out screencap -p`) |
| a fresh session | a scratch keyring, isolated from the operator's | the app's `flutter_secure_storage.dat` removed | `pm clear` of the app |
| Python interpreter | `python3` | `python` (`BOLTMESH_E2E_PYTHON` overrides both) | `python3` on the host, for device clearing only |

The "tunnel exists" row is the one worth reading twice. The obfuscated rung on
Windows runs an in-process AmneziaWG device over a Wintun adapter and registers
no `boltmesh0` *service*, so a service probe would read "no tunnel" mid-ladder;
the adapter is named `boltmesh0` on every rung, which is what makes it the
Windows analogue of `ip link show`. Android has no such external view at all —
`ip`, `wg` and `/proc/net/dev` are denied to the app uid — so its seam reads the
interface table from inside the process, where the app's own tun is visible.

## The four tests

Four tests, in order, each building on the last. They share one `flutter test`
process and one store, so the session and the device identity carry across them
— which is also what puts the restore path inside what is covered.

1. **signs in** — types the real credentials into the real form and reaches the
   VPN tabs. A stored session short-circuits this and says so; each runner
   starts from a fresh store (a scratch keyring on Linux, no secure-storage
   file on Windows, `pm clear` on Android), so a scripted run does drive the
   form.
2. **walks the transport ladder native, awg, stream, native** — pins the
   controller to each rung in turn through its `debugForceRung` seam (a walk the
   health policy would only take on a blocked network, which a lab run cannot
   fabricate). The first rung comes up through the Home power control; the
   others are restarts through the controller, reusing the bound session rather
   than spending the backend's shared write budget on a disconnect+connect pair
   per rung. For each rung it waits for `connected`, checks the UI agrees (the
   header names the server, the button reads Disconnect), and asserts on bytes:
   the app's own received counter, the kernel's `wg` counters when the kernel
   owns the data plane (Linux only; a userspace device has none, and the app's
   counters stand in), and an in-tunnel ping to that rung's own node address
   with no loss. It then descends back to `native`: the change *into* stock is
   the one transition the upward walk never makes — it tears the obfuscated rung
   down and brings a stock config up on the same single VpnService, through the
   same in-process host — so leaving it out let that hand-off regress
   unexercised. Finishes with one power-control
   disconnect that must leave the tunnel gone.
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

So the runner scripts delete the account's devices before the app starts, and
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
  tears down exactly when it must. Android needs no equivalent net at all: its
  tunnel is in-process, so the `VpnService` dies with the test app rather than
  following the device around.

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
backend stored. On Android the store is the app's own (cleared per run unless
`BOLTMESH_E2E_KEEP_SESSION=1`), so the same rerun-with-restore applies there.

`BOLTMESH_E2E_SHOT_DIR` (set by the script) makes the test screenshot the real
window at each stage. It is best effort: on Linux that is ImageMagick's `import`
reading the X display, on Windows `tool/e2e/screenshot.ps1` reading the primary
screen. Android takes none — the test cannot hand a device screenshot to the
host — but the runner can `adb exec-out screencap -p`. No tool, no pictures,
still a valid run.

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
