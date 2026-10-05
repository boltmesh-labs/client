# End-to-end harness

This proves the one thing unit tests cannot: that the client's bridge and the
node's ingress actually carry a real WireGuard tunnel's packets across a real TLS
session.

Both ends are real. The client half is this repository's `boltmeshd`, built from
source and spoken to over its real unix socket. The node half is a **real running
node** — one you already have, registered against the real API, heartbeating, and
serving its own ingress. There is no stub control plane and no second copy of the
agent: a node that has not registered has no WireGuard public key, cannot be bound
to a device, and advertises no transport at all, so a fixture standing in for one
would prove less, not more.

```text
  this host                          real node (test1, test2, ...)
  ┌────────────────────────┐          ┌────────────────────────────┐
  │ boltmeshd             │  TLS 1.3 │ agentd                     │
  │   wg-quick → boltmesh0│─────────▶│   wg0 (kernel wgctrl)      │
  │   stream bridge       │          │   stream ingress :443      │
  │   127.0.0.1:<listen>  │          │                            │
  └───────────┬────────────┘          └─────────────┬──────────────┘
              │        real API, in between         │
              └─── device create, config, PSK ──────┘
```

The API is in the middle because that is where it sits in production. It binds the
device to a serving node, hands the client the node's public key, the node's
tunnel address, and the stream credential, and it withholds the stream rung
entirely until the node has reported a TLS pin on its heartbeat. So the pin this
harness pins is one a live listener reported, and its presence is itself evidence
that the node is up.

## What it checks

1. The device is created through the real API and bound to a real serving node.
2. The tunnel comes up on the **stream** rung, using the credential and the SPKI
   pin the backend served for this device.
3. A kernel handshake completes, and the client interface actually received
   WireGuard bytes.
4. An in-tunnel ping to the node's tunnel address succeeds with no loss.
5. A wrong PSK moves no bytes: either the daemon refuses it outright, or no
   handshake completes and the counters stay at zero.

The **stream** rung is stock WireGuard inside its TLS session even on a node that
also serves the obfuscated rung, because the node's bridge injects into its stock
device. So this harness builds a stock conf, and the dial payload's obfuscation
parameters are deliberately never read — an AmneziaWG conf aimed at a stock device
would handshake with nobody, and the run would fail for a reason that has nothing
to do with the transport under test.

The ladder itself is not walked. Rung selection and demotion are the controller's
job and are covered by its own tests; what is untested without this harness is
whether the transport works at all once a rung has been chosen.

## Running it

Needs root (`wg` and `wg-quick` are privileged), `iproute2`, `wireguard-tools`,
`python3`, and a Go toolchain unless `--bin-dir` is given.

Credentials go through the environment, never a file or a flag: the process list
is world-readable, and a password there outlives the run.

```sh
sudo --preserve-env=BOLTMESH_E2E_API_USER,BOLTMESH_E2E_API_PASSWORD \
  tool/e2e/run.sh --region=us-east-99
```

| Flag | Meaning |
| --- | --- |
| `--region=ID` | required. The region to bind the device to; the API picks the node |
| `--bin-dir=DIR` | use a prebuilt `boltmeshd`, skipping the Go toolchain |
| `--keep` | leave the work directory up for inspection after a pass |

There is deliberately no flag for the node's address, port, or tunnel subnet. The
API assigns the node and is authoritative about all three, and a value supplied
alongside it is a second source of truth that can name a *different* node's network
than the one actually serving — which fails as "no route to host" and reads like a
broken transport. `AllowedIPs` is derived from the payload's own addresses instead.

`BOLTMESH_E2E_DEBUG=1` keeps the work directory and logs even when the run fails.
Without it a failed run keeps only its logs and a successful one removes both.

## The device identity

The run generates a WireGuard keypair and keeps it at
`~/.local/state/boltmesh/e2e-device-<region>.json` (0600), reusing it on later runs
against the same region. That path is the *invoking* user's, not root's — `sudo`
resets `$HOME`, and a keypair that lands in `/root` is neither visible to the
person who ran it nor removable by them. `BOLTMESH_E2E_STATE_DIR` overrides it.

That reuse is required, not a convenience. The backend stores only the public
half, and the node's peer table is built from it, so a fresh keypair under a
reused device name would leave the client holding a private key that no peer
matches — and the tunnel would never handshake, which reads as a network problem
rather than an identity mismatch. To start clean, delete that file; the device
name is derived from the key, so a new key is a new device rather than a
collision.

Nothing is provisioned on the backend ahead of the run. The device is created
through the real API, which binds it to a node that is already serving.

## Two traps worth keeping in mind

Both were found the hard way while building this, and both make a correct
implementation look broken:

- **A local address in the same namespace short-circuits routing**, so inner
  packets are never encapsulated and a test passes with zero WireGuard traffic.
  The harness asserts on transfer counters, not just on ping succeeding.
- **The inner format follows the rung, not the region.** A node can serve stock,
  obfuscated and stream at once, and the stream rung's datagrams are *stock* —
  the bridge injects into the stock device. Copying the region's obfuscation
  parameters onto a stream start produces a conf that handshakes with nobody.

## The app, not just the daemon

`run.sh` stops at `boltmeshd`: it speaks the socket protocol itself, so every
layer above the helper — the login form, the auth gate, provisioning, rung
selection, the power button, session restore, the traffic card — is untested by
it. `run_linux_app.sh` closes that gap by running the actual Linux desktop app
under `integration_test/linux_app_e2e.dart`: real window, real widgets, real
typed credentials, real taps.

```sh
sudo --preserve-env=BOLTMESH_E2E_API_USER,BOLTMESH_E2E_API_PASSWORD \
  tool/e2e/run_linux_app.sh
```

It builds and installs `boltmeshd` from source (needs `sudo` and a Go
toolchain), so the run always exercises the current helper code. It also needs
this user enrolled in the `boltmesh` group.

What it asserts, in order: sign-in reaches the VPN tabs; the Home tab's power
control drives a real connect; the phase reaches `connected` **and** the UI
agrees (the header shows the server, the button reads Disconnect); received
bytes appear; the kernel's own `wg` counters moved too when the kernel owns the
data plane; an in-tunnel ping to the node succeeds with no loss; and
disconnecting removes `boltmesh0` from the host. The last one matters most: this
box *is* the client, so a leftover full-tunnel would outlive the run.

The app runs on a virtual display and an isolated keyring, both of which the
script sets up because they are lab facts rather than app behaviour:

| | Why |
| --- | --- |
| `Xvfb` on `:99` | a headless box has no display; `BOLTMESH_E2E_DISPLAY` overrides |
| `XDG_DATA_HOME` + `gnome-keyring-daemon --unlock` | the app persists its session and device keys through libsecret, which needs an unlocked collection. Isolating it means a lab run cannot read or rewrite the operator's real login keyring, and it can never leave one locked |

Credentials come from the environment like `run.sh`'s. `.env` supplies the
API URL as `--dart-define-from-file`, the same way `make run` does; point it
elsewhere with `ENV_FILE=staging.env`.

Session restore is exercised rather than avoided: a rerun against the same work
directory comes up already signed in, and the test says so and skips the form.
The device identity lives in that keyring too, so it is reused between runs,
which is required for the same reason `run.sh` reuses its keypair — the node's
peer table is built from the public half the backend stored.

`BOLTMESH_E2E_SHOT_DIR` (set by the script) makes the test screenshot the real
window at each stage with ImageMagick's `import`. It is best effort: no
`import`, no pictures, still a valid run.

## Self-tests

`test_harness.py` covers the harness's own logic and needs no root, no node, and no
kernel module:

```sh
python3 tool/e2e/test_harness.py
```

A fixture that reports PASS while exercising nothing is worse than no fixture, so
these cover the conf construction and the transport-spec assembly — including that
the stream credential is read off the advertised `transports` list rather than a
top-level field, which is the mistake that would pin one rung's credential to
another.

## What it does not prove

A pass rules out implementation defects between the two halves. It does not test
real NAT, a real enterprise/campus IPS, or any evasion property, and it says
nothing about a node that is not currently serving. This is deliberately not an
anti-probing construction — see `boltmeshd/README.md`.
