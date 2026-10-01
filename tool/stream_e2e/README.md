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

Two network namespaces on one Linux host, joined by a veth pair, each running its
own helper as a separate process:

```text
 netns client                          netns node
 ┌──────────────────────────┐          ┌────────────────────────────┐
 │ boltmeshd (root)         │          │ agentd                     │
 │   wg-quick → wg0         │          │   wg0 (kernel wgctrl)      │
 │   internal/stream bridge │          │   internal/stream ingress  │
 │     127.0.0.1:<listen>   │          │     0.0.0.0:<stream_port> │
 └───────────┬──────────────┘          └──────────────┬─────────────┘
             │        TLS 1.3 over the veth pair        │
             └─────────────────────────────────────────┘
```

1. `controlplane.py` starts: a stub control plane serving registration, heartbeat,
   peers-sync, and token re-mints. It holds the one device credential both ends
   are handed, so the client and the node cannot disagree about the PSK.
2. `agentd` registers against it, receives a `stream_ingress` descriptor, **mints
   its own certificate**, and starts the ingress.
3. The node reports its SPKI pin on the heartbeat. The harness reads the pin back
   from the stub — so the client's pin comes from a node that actually bound its
   port, never from a fixture constant.
4. `boltmeshd` starts with its own wg-quick config whose peer `Endpoint` is the
   bridge's loopback address and whose `ListenPort` is the bridge's deliver port.
5. `client.py` sends `up` with a `transport` spec carrying that pin.
6. The harness asserts a kernel handshake on both sides, 0% loss on an in-tunnel
   ping, and that the two `wg` interfaces see each other's keys.

## Requirements

Root (namespaces, veth, and `wg` are all privileged), plus:

- `iproute2`, `wireguard-tools` (`wg`, `wg-quick`), `python3`, and a working
  kernel WireGuard module
- both repos buildable (`go build ./...` in `boltmeshd/` and in the agent repo)

## Running it

```sh
# From the client repo root.
sudo tool/stream_e2e/run.sh
```

Flags, all optional:

| Flag | Default | Meaning |
| --- | --- | --- |
| `--agent-repo=PATH` | `../agent` | agent checkout, for its `go.mod` |
| `--keep` | off | leave the namespaces up for manual poking |
| `--skip-build` | off | reuse existing binaries |

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
