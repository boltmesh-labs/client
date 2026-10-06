#!/usr/bin/env python3
"""Decide, from Suricata's `eve.json`, whether each transport rung is visible.

`run.sh` starts Suricata under the installed WireGuard rules
(`/etc/suricata/rules/local.rules`) while the app e2e harness walks the
transport ladder native -> awg -> stream, then hands the eve log to this
checker. The claim under test is asymmetric:

  - **native** must trip the WireGuard fingerprints, because it is WireGuard's
    own UDP on the wire;
  - **awg** and **stream** must not, because one replaces the protocol magic
    and pads it, and the other carries the same datagrams inside TLS to :443.

A "no alert" result only means something if the traffic actually happened and
the rules were actually loaded, so this checker refuses to pass on silence:

  - the positive control (`9900001`) must have fired;
  - each rung must show traffic on its own endpoint, by flow or by the
    adversarial control that is *expected* to fire there;
  - native must show its own signature, and awg/stream must show none of them.

Events are attributed to a rung by endpoint (the node's address and the rung's
own port), not by wall-clock time, so a slow sign-in or an intervening server
move cannot misclassify an alert.

Run the self-tests with `python3 tool/suricata/test_checker.py`; they need no
root and no node.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

# The subject rules, installed as /etc/suricata/rules/local.rules.
HANDSHAKE_SID = 9900002
TRANSPORT_SID = 9900003
PORT_SID = 9900004
WG_SIDS = frozenset({HANDSHAKE_SID, TRANSPORT_SID, PORT_SID})

# The controls from rules/controls.rules.
ENGINE_LIVE_SID = 9900001
AWG_PORT_ADV_SID = 9900005
AWG_H1_ADV_SID = 9900006
STREAM_TLS_ADV_SID = 9900007
ADVERSARIAL_SIDS = frozenset({AWG_PORT_ADV_SID, AWG_H1_ADV_SID, STREAM_TLS_ADV_SID})

# The optional harder tier (rules/challenging.rules). Informational: it is
# expected to catch awg (traffic analysis) and stream (TLS), which is the point
# of running it, so these alerts never fail the run — they qualify it.
HARD_SIDS = frozenset(range(9920001, 9920100))


@dataclass(frozen=True)
class Rung:
    """One transport rung, identified by the node endpoint it talks to."""

    name: str
    proto: str  # "UDP" or "TCP"
    port: int


@dataclass
class RungReport:
    """What Suricata saw on one rung."""

    rung: Rung
    wg_alerts: list[int] = field(default_factory=list)
    adversarial: list[int] = field(default_factory=list)
    hard: list[int] = field(default_factory=list)
    flows: int = 0
    tls_events: int = 0
    tls_version: str | None = None
    tls_sni: str | None = None

    @property
    def wg_sids(self) -> list[int]:
        return sorted(set(self.wg_alerts))

    @property
    def adversarial_sids(self) -> list[int]:
        return sorted(set(self.adversarial))

    @property
    def hard_sids(self) -> list[int]:
        return sorted(set(self.hard))

    @property
    def has_traffic(self) -> bool:
        return bool(self.wg_alerts or self.adversarial or self.hard or self.flows or self.tls_events)


def load_events(path: str) -> list[dict]:
    """Read a JSON-lines eve log, tolerating a truncated final line."""
    events: list[dict] = []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def signature_id(event: dict) -> int | None:
    alert = event.get("alert")
    if not isinstance(alert, dict):
        return None
    return alert.get("signature_id")


def _proto(event: dict) -> str:
    return str(event.get("proto", "")).upper()


def on_endpoint(event: dict, node: str, rung: Rung) -> bool:
    """True when either endpoint of `event` is the node on this rung's port."""
    if _proto(event) != rung.proto:
        return False
    return (
        event.get("src_ip") == node and event.get("src_port") == rung.port
    ) or (
        event.get("dest_ip") == node and event.get("dest_port") == rung.port
    )


def analyze(
    events: list[dict], node: str, rungs: list[Rung]
) -> tuple[bool, dict[str, RungReport]]:
    """Return (positive control fired, per-rung report)."""
    alerts = [e for e in events if e.get("event_type") == "alert"]
    engine_live = any(signature_id(e) == ENGINE_LIVE_SID for e in alerts)

    reports: dict[str, RungReport] = {}
    for rung in rungs:
        report = RungReport(rung)
        for event in events:
            if not on_endpoint(event, node, rung):
                continue
            kind = event.get("event_type")
            if kind == "alert":
                sid = signature_id(event)
                if sid in WG_SIDS:
                    report.wg_alerts.append(sid)
                if sid in ADVERSARIAL_SIDS:
                    report.adversarial.append(sid)
                if sid in HARD_SIDS:
                    report.hard.append(sid)
            elif kind == "flow":
                report.flows += 1
            elif kind == "tls":
                report.tls_events += 1
                tls = event.get("tls")
                if isinstance(tls, dict):
                    report.tls_version = report.tls_version or tls.get("version")
                    report.tls_sni = report.tls_sni or tls.get("sni")
        reports[rung.name] = report
    return engine_live, reports


def evaluate(
    engine_live: bool, reports: dict[str, RungReport], expect_port_rule: bool
) -> list[str]:
    """Return a list of failure strings; empty means the run passed."""
    failures: list[str] = []
    if not engine_live:
        failures.append(
            f"positive control (sid {ENGINE_LIVE_SID}) did not fire: Suricata, "
            "the extra rules, or the control datagram were not live"
        )

    native = reports["native"]
    if HANDSHAKE_SID not in native.wg_alerts and TRANSPORT_SID not in native.wg_alerts:
        failures.append(
            "native rung: neither the handshake nor the transport signature fired "
            f"({HANDSHAKE_SID}/{TRANSPORT_SID}); expected WireGuard to be visible"
        )
    if expect_port_rule and PORT_SID not in native.wg_alerts:
        failures.append(
            f"native rung: the port rule ({PORT_SID}) did not fire; expected the "
            "native port to be visible"
        )

    awg = reports["awg"]
    if awg.wg_alerts:
        failures.append(
            f"awg rung: WireGuard signature(s) fired {awg.wg_sids}; AWG was "
            "supposed to be invisible to them"
        )
    if not awg.has_traffic:
        failures.append(
            "awg rung: no traffic was observed on the AWG endpoint at all, so a "
            "clean signature result proves nothing"
        )

    stream = reports["stream"]
    if stream.wg_alerts:
        failures.append(
            f"stream rung: WireGuard signature(s) fired {stream.wg_sids}; the "
            "stream was supposed to be invisible to them"
        )
    if not stream.has_traffic:
        failures.append(
            "stream rung: no traffic was observed on the stream endpoint at all, "
            "so a clean signature result proves nothing"
        )
    return failures


def format_table(reports: dict[str, RungReport], engine_live: bool) -> str:
    lines = []
    for name in ("native", "awg", "stream"):
        report = reports[name]
        sids = ",".join(str(s) for s in report.wg_sids) or "-"
        adv = ",".join(str(s) for s in report.adversarial_sids) or "-"
        hard = ",".join(str(s) for s in report.hard_sids) or "-"
        tls = ""
        if report.tls_events:
            parts = [f"{report.tls_events}"]
            if report.tls_version:
                parts.append(report.tls_version)
            if report.tls_sni:
                parts.append(report.tls_sni)
            tls = " ".join(parts)
        lines.append(
            f"  {name:<7} {report.rung.proto}/{report.rung.port:<6} "
            f"wg={sids:<20} adversarial={adv:<16} hard={hard:<16} "
            f"flows={report.flows:<4} tls={tls or '-'}"
        )
    lines.append(f"  control: engine-live={'yes' if engine_live else 'NO'}")
    return "\n".join(lines)


def build_rungs(args: argparse.Namespace) -> list[Rung]:
    return [
        Rung("native", "UDP", args.native_port),
        Rung("awg", "UDP", args.awg_port),
        Rung("stream", "TCP", args.stream_port),
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--eve", required=True, help="path to the run's eve.json")
    parser.add_argument("--node", required=True, help="the serving node's address")
    parser.add_argument("--native-port", type=int, default=51820)
    parser.add_argument("--awg-port", type=int, default=51821)
    parser.add_argument("--stream-port", type=int, default=443)
    parser.add_argument(
        "--expect-port-rule",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="require sid 9900004 (its rule is hardcoded to the native port 51820)",
    )
    args = parser.parse_args(argv)

    if not Path(args.eve).exists():
        print(f"check: no eve log at {args.eve}", file=sys.stderr)
        return 2

    rungs = build_rungs(args)
    events = load_events(args.eve)
    engine_live, reports = analyze(events, args.node, rungs)
    failures = evaluate(engine_live, reports, args.expect_port_rule)

    print("Suricata transport visibility:")
    print(format_table(reports, engine_live))
    print()
    if failures:
        print(f"FAIL ({len(failures)}):")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("PASS: native is visible to the WireGuard rules; awg and stream are not.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
