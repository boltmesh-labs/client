# Suricata transport-visibility harness

This proves — against Suricata, not against a description of Suricata — which
BoltMesh transport rungs a network security monitor can see.

- **native** is WireGuard's own UDP on the wire, so the installed WireGuard
  rules must fire on it.
- **awg** is AmneziaWG: the same tunnel with the protocol magic replaced and
  padded, so those same rules must not fire.
- **stream** carries the tunnel's datagrams inside a TLS 1.3 session to the
  node's ingress, so the rules must not fire — it is indistinguishable from
  ordinary HTTPS, not absent from the wire.

The point of a harness rather than a one-off is that "no alert" is a weak
result on its own. This one refuses to pass on silence: it sends a positive
control first, and it requires evidence that each rung actually produced
traffic before it will accept a clean signature result.

## Running it

Suricata needs root for `af-packet`, and the e2e installs the privileged
helper, so the run needs `sudo`. The API credentials come from the e2e's
environment file, never a flag.

```sh
sudo --preserve-env=BOLTMESH_E2E_API_USER,BOLTMESH_E2E_API_PASSWORD \
  tool/suricata/run.sh
```

It drives `tool/e2e/run_linux_app.sh`, so the same prerequisites apply: a
display (`Xvfb` is set up by that script), `gnome-keyring`, a Go toolchain, and
this user in the `boltmesh` group. **The e2e is destructive to the test
account's devices** — it clears them first — so point it at a lab account. See
`tool/e2e/README.md`.

A control-only plumbing check, with no ladder and no credentials:

```sh
SURICATA_SKIP_E2E=1 tool/suricata/run.sh
```

That is expected to *fail* its verdict (there is no native/awg/stream traffic);
it is there to confirm Suricata starts, the positive control fires, and the
checker runs.

The checker alone, against a saved log:

```sh
python3 tool/suricata/check_flows.py --eve /path/to/eve.json --node 192.168.1.115
```

## What it checks

The subject rules are the installed `/etc/suricata/rules/local.rules`, loaded
by the production config. This harness adds its own controls on top (`sudo
suricata -s`), so it cannot pass by quietly swapping out the ruleset under
test.

| sid | kind | what it means |
| --- | --- | --- |
| 9900002 | subject | WireGuard handshake initiation (`01 00 00 00`) |
| 9900003 | subject | WireGuard transport data / keepalive (`04 00 00 00`) |
| 9900004 | subject | any UDP to the native port |
| 9900001 | control | the synthetic magic — proves the engine and rules loaded |
| 9900005 | adversarial | the AWG endpoint as plain UDP on its port |
| 9900006 | adversarial | AWG with a **known** `h1` magic (opt-in, see below) |
| 9900007 | adversarial | the stream rung as ordinary TLS 1.3 |

Pass requires all of:

- the positive control fired;
- native tripped `9900002`/`9900003` (and `9900004`);
- awg tripped none of `9900002`/`9900003`/`9900004`, **and** showed traffic on
  its endpoint;
- stream tripped none of them, **and** showed traffic on its endpoint.

## What each result does and does not mean

- **native**: detectable by protocol fingerprint alone. Only the outer
  handshake headers and packet shape are visible; the payload is encrypted
  either way.
- **awg**: invisible *to these generic signatures*. It is not invisible on the
  wire — `9900005` fires because the flow is plain UDP to a port. A detector
  that knows the node's parameters can still catch it: set
  `SURICATA_AWG_H1=<hex bytes>` to emit the `9900006` rule matching the
  configured `h1` magic and watch it fire. If `h1` is configured as a *range*
  the handshake magic varies per message, and even a targeted static rule
  becomes probabilistic — which is the honest boundary of the claim.
- **stream**: invisible *as WireGuard*. It is fully visible as TLS 1.3 to the
  node's ingress — SNI, ALPN, JA3/JA4 (`9900007` fires). The right statement
  is "indistinguishable from HTTPS to a VPN provider", not "not on the wire".
  A policy that blocks unknown TLS endpoints would catch it.

## Parameters

All optional; the defaults describe the lab this was built on.

| variable | default | meaning |
| --- | --- | --- |
| `SURICATA_IFACE` | `ens160` | interface to capture |
| `SURICATA_NODE_IP` | `192.168.1.115` | serving node |
| `SURICATA_NATIVE_PORT` | `51820` | native rung's UDP port |
| `SURICATA_AWG_PORT` | `51821` | awg rung's UDP port |
| `SURICATA_STREAM_PORT` | `443` | stream rung's TLS port |
| `SURICATA_CONTROL_PORT` | `59999` | where the positive control is sent |
| `SURICATA_CONFIG` | `/etc/suricata/suricata.yaml` | Suricata config |
| `SURICATA_AWG_H1` | unset | hex `h1` magic for the targeted-detector control |
| `SURICATA_LOG_DIR` | `/tmp/opencode/suricata-<ts>` | artifacts (eve log, pcap, logs) |
| `SURICATA_SKIP_E2E` | `0` | `1` skips the ladder (plumbing check) |
| `BOLTMESH_E2E_CREDS_FILE` | `.env.e2e` | e2e credentials |

## Self-tests

The checker's attribution and verdict logic is covered without root, a node, or
Suricata:

```sh
python3 tool/suricata/test_checker.py
```

## What it does not prove

A pass rules out these specific generic signatures on these specific wire
formats. It does not test a real enterprise or campus IPS, an active prober, or
a detector that has learned the deployment's exact obfuscation parameters. It
also says nothing about a node that is not currently serving.
