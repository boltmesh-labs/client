# End-to-end harness

This proves the one thing unit tests cannot: that the real Linux desktop app,
driving the real privileged `boltmeshd`, brings a real WireGuard tunnel up to a
real serving node and moves packets across it — on every rung the node serves.

Both ends are real. The client half is the app, built from source and run under
`integration_test/linux_app_e2e.dart`; the node half is a **real running node** —
one you already have, registered against the real API, heartbeating, and serving
its own ingress. There is no stub control plane and no second copy of the agent:
a node that has not registered has no WireGuard public key, cannot be bound to a
device, and advertises no transport at all, so a fixture standing in for one
would prove less, not more.

```text
  this host                          real node (test1, test2, ...)
  ┌────────────────────────┐          ┌────────────────────────────┐
  │ Flutter app            │          │ agentd                     │
  │   ↓ helper socket      │  TLS 1.3 │   wg0 (kernel wgctrl)      │
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

Needs `flutter`, `Xvfb`, `gnome-keyring-daemon`, `secret-tool`, `python3`, and a
Go toolchain, plus `sudo` for the one privileged step: installing the helper.

Credentials go through the environment, never a file or a flag: the process list
is world-readable, and a password there outlives the run.

Two steps — privileged install, then the unprivileged run:

```sh
sudo tool/e2e/install_boltmeshd.sh

tool/e2e/run_linux_app.sh
```

`install_boltmeshd.sh` is the only part that runs as root: it builds
`boltmeshd` from source and installs it, so the run always exercises the
current helper code. `run_linux_app.sh` runs entirely as the normal user (it
refuses root and `sudo`, because `flutter` itself refuses root). Both need
this user enrolled in the `boltmesh` group.

`.env` supplies the API URL as `--dart-define-from-file`, the same way `make run`
does; point it elsewhere with `ENV_FILE=staging.env`.

## The four tests

Four tests, in order, each building on the last. They share one `flutter test`
process and one keyring, so the session and the device identity carry across
them — which is also what puts the restore path inside what is covered.

1. **signs in** — types the real credentials into the real form and reaches the
   VPN tabs. A stored session short-circuits this and says so; the runner script
   starts from a fresh keyring, so a scripted run does drive the form.
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
   Regions tab and asserts the live dial moved to it. With only one server on
   offer there is nothing to switch *to*, so it exercises Quick Connect instead
   and says which path it took.
4. **logs out** — connects first, so logout has a live tunnel to tear down, then
   signs out and asserts the login screen is back and the interface is gone.

### Clearing devices first

The subscription caps how many devices can be active, and a run that fails
part-way leaves its row behind: the interface is gone, the row is not. The *next*
run then cannot provision and reports a device limit that the run reporting it
never caused — a bad way to fail, because the run that broke is long gone.

So `run_linux_app.sh` deletes the account's devices before the app starts, and
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

The app runs on a virtual display and an isolated keyring, both of which the
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
window at each stage with ImageMagick's `import`. It is best effort: no
`import`, no pictures, still a valid run.

## Self-tests

`test_harness.py` covers the harness's own logic and needs no root, no node, and
no display:

```sh
python3 tool/e2e/test_harness.py
```

A fixture that reports PASS while exercising nothing is worse than no fixture, so
these cover the helper protocol `client.py` speaks and the device clearing
`run_linux_app.sh` runs before the app starts.

## What it does not prove

A pass rules out implementation defects between the two halves. It does not test
real NAT, a real enterprise/campus IPS, or any evasion property, and it says
nothing about a node that is not currently serving. This is deliberately not an
anti-probing construction — see `boltmeshd/README.md`.
