# Stream transport end-to-end harness

This harness proves the one thing unit tests cannot: that the client's bridge
and the node's ingress, built from **two independent implementations** in two
separate Go modules, actually carry a real WireGuard tunnel's packets across a
real TLS session between two real processes.

Nothing here runs a real DPI middlebox, so it says nothing about *undetectability*.
What it rules out is the class of failure where both halves pass their own tests
— against golden vectors, against a fake kernel, against a test-local dial helper
— and still do not interoperate. The agent's `internal/stream` tests drive the
ingress against a **UDP echo stand-in** for the kernel and a **hand-rolled** client
half; nothing before this point had ever put real `wg` interfaces on both ends of
the real client code.

## What it does

A bridge on the host gives every participant one address family, and each helper
runs as its own process in its own namespace:

```text
                 host  br-bm  192.168.100.1
                  │  (stub control plane: registration, heartbeat, peers-sync)
        ┌─────────┴──────────┐
        │                    │
 netns bm-client       netns bm-node
 192.168.100.2         192.168.100.3
 ┌──────────────────┐  ┌────────────────────────────┐
 │ boltmeshd        │  │ agentd                     │
 │   wg-quick → wg0 │  │   wg0 (kernel wgctrl)      │
 │   stream bridge  │  │   stream ingress           │
 │   127.0.0.1:<listen> │  0.0.0.0:<stream_port>   │
 └────────┬─────────┘  └─────────────┬──────────────┘
          │      TLS 1.3 over the bridge    │
          └─────────────────────────────────┘
```

The host leg is not decoration. A network namespace has its **own** loopback, so
a stub control plane bound to the host's `127.0.0.1` is unreachable from inside
either namespace — without the bridge leg the agent could never register.

1. `controlplane.py` starts on the host: a stub serving registration, heartbeat,
   peers-sync, and token re-mints. It holds the one device credential both ends
   are handed, so the client and the node cannot disagree about the PSK.
2. `agentd` registers against it, receives a `stream_ingress` descriptor, **mints
   its own certificate**, and starts the ingress.
3. The node reports its SPKI pin on the heartbeat. The harness reads the pin back
   from the stub — so the client's pin comes from a node that actually bound its
   port, never from a fixture constant.
4. `boltmeshd` starts with its own config whose peer `Endpoint` is the bridge's
   loopback address and whose `ListenPort` is the bridge's deliver port. On an
   obfuscated region the conf also carries the region's AmneziaWG directives, so
   the daemon runs the userspace device rather than wg-quick: the inner format
   follows the region, and the bridge carries whatever the node's device expects.
5. `client.py` sends `up` with a `transport` spec carrying that pin.
6. The harness asserts a kernel handshake on both sides, 0% loss on an in-tunnel
   ping, and that the client interface actually received WireGuard bytes. A
   wrong-PSK session is then driven and must be refused.
7. Against an obfuscated region, `client.py --force-native` builds the inner conf
   as stock WireGuard — exactly the attempt a client that ignored the region's
   format would make. The node runs the AmneziaWG device, so that session must
   complete no handshake and move no bytes. It is the premise the ladder's floor
   rests on (see `conn_obfuscation.dart`): a native start there can only fail,
   after leaking the plaintext fingerprint. Drive it by hand against an
   obfuscated staging region.

## Running it against a real control plane

The stub builds its descriptors by hand, so it proves the transport but says
nothing about the contract. To check that the real schemas produce something the
helpers accept — the only way to catch a field name drifting between three repos
in three languages — point the harness at a deployed backend.

Provision first. This is idempotent and resumable, and it writes the device's
keypair, the node's bootstrap secret and the ids to one 0600 state file:

```sh
./staging_setup.py --api-base https://api.example.com/v1 \
  --user <user> --password <password> \
  --server-name node.example.test \
  --state-out /tmp/staging-state.json
```

Two things it cannot do, both by design:

- A region's stream policy (`stream_enabled`, `stream_listen_port`) has no admin
  write surface yet, so it is set directly in the database. The script prints the
  statement rather than leaving a region that silently serves nothing.
- The device cannot be created until the node has registered: a server has no
  WireGuard public key until a node claims it, and binding refuses a server that
  is not dialable. That is why the device step also happens inside the run.

Then either run both ends, or just the client against a node you already have:

```sh
# Both ends, with the harness's own node, against the real API.
sudo BOLTMESH_E2E_API_USER=... BOLTMESH_E2E_API_PASSWORD=... \
  tool/stream_e2e/run.sh --staging-state=/tmp/staging-state.json

# Client half only, against a node this harness does not own — a real host with
# a baked firewalld zone and a read-only rootfs. Runs in the host namespace,
# because a bare namespace cannot reach a node on the LAN.
sudo BOLTMESH_E2E_API_USER=... BOLTMESH_E2E_API_PASSWORD=... \
  tool/stream_e2e/run.sh --client-only --staging-state=/tmp/staging-state.json \
  --tunnel-cidr=10.1.0.0/16
```

`--tunnel-cidr` is the node's tunnel subnet, for the conf's `AllowedIPs`. The
dial payload carries the node's tunnel *address* but not the prefix length it
sits in, and a `/32` there would leave the tunnel unroutable.

Credentials go through the environment, never the state file: the file already
holds a bootstrap secret and a private key, and adding an account password to a
file that gets copied between hosts is not worth the convenience.

## Requirements

Root (namespaces, veth, and `wg` are all privileged), plus `iproute2`,
`wireguard-tools`, `python3`, and a working kernel WireGuard module.

A Go toolchain is needed **only to build the two helpers**. To run a box without
one, cross-compile elsewhere and point the harness at the binaries:

```sh
GOOS=linux GOARCH=amd64 go build -o /tmp/e2e/boltmeshd ./cmd/boltmeshd
(cd ../agent && GOOS=linux GOARCH=amd64 go build -o /tmp/e2e/agentd ./cmd/agentd)
sudo tool/stream_e2e/run.sh --bin-dir=/tmp/e2e
```

## What a real box needs, and what the harness does about it

Each of these was found by running the harness on a stock Rocky 10 host, and each
one fails in a way that points somewhere other than the cause:

| Symptom | Cause | What the harness does |
| --- | --- | --- |
| `No route to host` from a namespace, **while ping works** | firewalld puts the new bridge in the `public` zone, which rejects unsolicited TCP with ICMP host-prohibited | places the bridge in the `trusted` zone for the run, removes it after |
| agent exits `INVALID_ZONE: vpn` | the `vpn` firewalld zone is baked in by the AMI build; a bare box has none | creates it (`--permanent` + reload, firewalld's only way) and removes it after, if it created it |
| agent exits `must use https://` | it refuses cleartext HTTP to a non-loopback host, by design | sets `ALLOW_INSECURE_HTTP=true`; the lab bridge is not loopback |
| `unknown group boltmesh` | `boltmeshd` defaults its socket group to a packaged-install artifact | `BOLTMESHD_SOCKET_GROUP=""` (root-only) |
| `wg-quick` fails on the **mtu** step with `Address already in use` | a port conflict, reported against the wrong command — see below | pins `ListenPort` to the bridge's *deliver* port, never its listen port |
| `wg-quick` fails `Failed to set DNS configuration` | `resolvconf` talks to a resolver in the host namespace, which does not know this namespace's interface | omits the `DNS=` line; DNS is out of scope here |

The mtu one is worth spelling out, because it is the mistake that makes a working
transport look broken. `wg-quick` echoes each command before running it, so a
failure on `ip link set mtu ... up` is reported *after* the address line. That
command returns `EADDRINUSE` when the WireGuard listen port is already bound — so
configuring `ListenPort` as the bridge's listen port, rather than its deliver
port, surfaces as an address error on a step that has nothing to do with
addresses.

Note also that `set -o pipefail` plus an unguarded `wg show <iface>` in a command
substitution kills the script silently when the interface name is wrong, which
reads as "the run just stopped". The harness names both interfaces explicitly
(`boltmesh0` on the client, the control plane's `interface_name` on the node) and
guards every read.

## Running it

```sh
# From the client repo root.
sudo tool/stream_e2e/run.sh
```

Flags, all optional:

| Flag | Default | Meaning |
| --- | --- | --- |
| `--agent-repo=PATH` | `../agent` | agent checkout, to build `agentd` from |
| `--bin-dir=DIR` | none | use prebuilt `boltmeshd`/`agentd`; skips the Go toolchain entirely |
| `--keep` | off | leave the network up for manual poking |
| `--skip-build` | off | requires `--bin-dir`; the work directory is per-run |

`BOLTMESH_E2E_DEBUG=1` keeps the network *and* the logs even when the run fails,
so the live namespaces can be inspected. Without it a failed run keeps only its
logs, and a successful one removes both.

Set `--keep` and then, from the host:

```sh
ip netns exec bm-client wg show      # handshake age, rx/tx
ip netns exec bm-node   wg show
```

## The two traps this harness exists to avoid

Both were found the hard way while validating the design, and both make a correct
implementation look broken:

- **The kernel `wg` device installs no routes for peer allowed-ips.** `wg-quick`
  adds them; a bare `wg set` does not. `ip route get` inside the namespace returns
  "Network is unreachable" for a peer's address until the route exists.
- **A local address in the same namespace short-circuits routing**, so inner
  packets are never encapsulated and a test passes with zero WireGuard traffic. The
  harness therefore asserts on `wg show` transfer counters, not just on ping
  succeeding.

## What it does not prove

An end-to-end run rules out implementation defects between the two halves. It does
not test real NAT, a real enterprise/campus IPS, or any evasion property. This is
deliberately not an anti-probing construction — see `boltmeshd/README.md`.
