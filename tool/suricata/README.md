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
| 9900002 | subject | WireGuard handshake initiation (type 1, 148, to_server) |
| 9900012 | subject | WireGuard handshake response (type 2, 92, to_client) |
| 9900013 | subject | WireGuard cookie reply (type 3, 64, to_client) |
| 9900003 | subject | WireGuard transport data / keepalive (type 4, ≥32) |
| 9900004 | subject | any UDP to the native port |
| 9900001 | control | the synthetic magic — proves the engine and rules loaded |
| 9900005 | adversarial | the AWG endpoint as plain UDP on its port |
| 9900006 | adversarial | AWG with a **known** `h1` magic (opt-in, see below) |
| 9900007 | adversarial | the stream rung as ordinary TLS 1.3 |
| 9920xxx | hard | the optional harder tier (`SURICATA_HARD=1`), see below |
| 9930xxx | traffic | the optional traffic-analysis tier (`SURICATA_TRAFFIC=1`), see below |

Pass requires all of:

- the positive control fired;
- native tripped `9900002`/`9900003` (and `9900004`);
- awg tripped none of `9900002`/`9900003`/`9900004`, **and** showed traffic on
  its endpoint;
- stream tripped none of them, **and** showed traffic on its endpoint.

The `9920xxx` hard rules never fail the run — they are expected to catch awg
and stream and are reported to qualify the result.

## The harder tier (`SURICATA_HARD=1`)

The base run answers a narrow question: do generic *WireGuard protocol*
signatures catch each rung? Set `SURICATA_HARD=1` to also load
`rules/challenging.rules`, which answers the harder one — what a detector
willing to use traffic analysis and TLS fingerprinting sees. Measured on the
same run:

| rung | WireGuard-signature rules | the harder tier |
| --- | --- | --- |
| native | caught (type1 148, type2 92, type4, keepalive) | caught |
| awg | **missed** | **caught** by padding-aware size (`9920010`) and payload entropy (`9920011`) |
| stream | **missed** | **caught** as TLS 1.3 + ALPN `h2` (`9920020`/`9920021`), JA3 `1bcbceb7…`, JA4 `t13d0312h2…` |

Two consequences, and they are the honest bottom line:

- **"awg is invisible"** holds only against protocol fingerprints. Its padded
  handshake still lands in a knowable size window, and its payloads are still
  high-entropy UDP. Both are real detections; both are also high-false-positive
  heuristics, which is why they are not in the installed ruleset.
- **"stream is invisible"** holds only against WireGuard signatures. It is
  ordinary TLS 1.3 and is trivially caught by a TLS rule or a JA3/JA4 blocklist.
  The correct claim is "indistinguishable from HTTPS to a VPN provider", not
  "not detectable".

## The traffic-analysis tier (`SURICATA_TRAFFIC=1`)

The harder tier still keys on *something* — a size window, a TLS field. This
tier keys on nothing but **flow shape**: how much, how long, in which
direction, and how random. It loads `rules/traffic.rules` (sids `9930xxx`) and
then prints a per-flow feature report from `traffic_features.py`, which is the
real substance; the rules are only the alerting face of it.

The features exclude ports and IP addresses — those are used only to *label* a
flow against the run's known topology — so this is genuinely not port or
protocol analysis. Measured on the committed run:

| flow | pkts | bytes | first payload | size mean (min–max) | entropy |
| --- | --- | --- | --- | --- | --- |
| native (UDP) | 113 | 33,172 | **148** | 293.6 (32–1452) | 6.35 |
| awg (UDP) | 92 | 26,616 | **3** | 289.3 (3–1457) | 6.59 |
| stream (TCP) | 100 | 24,046 | 1448 | 240.5 (24–1448) | 6.64 |
| baseline TLS (node↔API) | 40 | 8,354 | 700 | 417.7 (224–849) | 7.40 |
| baseline DNS | 2 | 96–216 | 48–108 | 64–108 | 0.68–3.78 |

What that shows, and its limits:

- the two UDP tunnels are indistinguishable *from each other* by size or
  entropy — both are ~26–33 kB over ~20 s, both ~6.5 bits/byte — so flow shape
  identifies "a sustained encrypted UDP flow", not "WireGuard" and not "awg";
- the first-payload size still separates them from each other (148-byte
  handshake vs a 3-byte awg junk packet), and separates both from the TLS
  baseline;
- entropy alone is not a VPN detector: the baseline TLS flows score *higher*
  (7.2–7.4) than the tunnels, because TLS records are also random. It separates
  encrypted from plaintext (DNS at 0.7–3.8), nothing finer.

Scope, honestly: one short capture with a handful of flows shows the observable
fingerprint and lets rungs be compared. It is not a classifier result — that
needs a labelled baseline and cross-validation over many flows, which this
harness does not claim to do.

## What each result does and does not mean

- **native**: detectable by protocol fingerprint alone. Only the outer
  handshake headers and packet shape are visible; the payload is encrypted
  either way.
- **awg**: invisible *to these generic WireGuard signatures*. It is not
  invisible on the wire — `9900005` fires because the flow is plain UDP to a
  port, and the harder tier catches it by size and entropy without knowing any
  node secret. A detector that knows the node's parameters can also catch it
  directly: set `SURICATA_AWG_H1=<hex bytes>` to emit the `9900006` rule
  matching the configured `h1` magic and watch it fire. If `h1` is configured
  as a *range* the handshake magic varies per message, and even that targeted
  static rule becomes probabilistic.
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
| `SURICATA_HARD` | `0` | `1` also loads `rules/challenging.rules` (traffic analysis + TLS) |
| `SURICATA_TRAFFIC` | `0` | `1` also loads `rules/traffic.rules` and prints the feature report (needs `tshark`) |
| `SURICATA_LOG_DIR` | `/tmp/opencode/suricata-<ts>` | artifacts (eve log, pcap, logs) |
| `SURICATA_SKIP_E2E` | `0` | `1` skips the ladder (plumbing check) |
| `BOLTMESH_E2E_CREDS_FILE` | `.env.e2e` | e2e credentials |

## Self-tests

The checker's attribution/verdict logic and the feature extractor's statistics
are covered without root, a node, tshark, or Suricata:

```sh
python3 tool/suricata/test_checker.py
python3 tool/suricata/test_traffic_features.py
```

## What it does not prove

A pass rules out these specific generic signatures on these specific wire
formats. It does not test a real enterprise or campus IPS, an active prober, or
a detector that has learned the deployment's exact obfuscation parameters. It
also says nothing about a node that is not currently serving.
