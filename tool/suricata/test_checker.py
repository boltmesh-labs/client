#!/usr/bin/env python3
"""Self-tests for the Suricata visibility checker's own logic.

The checker is a test fixture, and a broken fixture is worse than no fixture:
it reports PASS while exercising nothing. These cover the parts that can be
decided on a normal machine — attribution of events to a rung, and the pass/fail
rules — so a change to the classification cannot silently weaken the result.

Nothing here needs root, a node, or Suricata itself. Run directly:

    python3 tool/suricata/test_checker.py
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, _HERE / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    # Register before execution: dataclasses resolves a class's module through
    # sys.modules, which is empty for a by-path import on Python 3.14.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


check = _load("suricata_check_flows", "check_flows.py")

NODE = "192.168.1.115"
RUNGS = [
    check.Rung("native", "UDP", 51820),
    check.Rung("awg", "UDP", 51821),
    check.Rung("stream", "TCP", 443),
]


def alert(sid: int, *, src_ip: str, src_port: int, dest_ip: str, dest_port: int,
          proto: str) -> dict:
    return {
        "event_type": "alert",
        "src_ip": src_ip,
        "src_port": src_port,
        "dest_ip": dest_ip,
        "dest_port": dest_port,
        "proto": proto,
        "alert": {"signature_id": sid, "rev": 1, "signature": f"sig {sid}"},
    }


def flow(*, src_ip: str, src_port: int, dest_ip: str, dest_port: int, proto: str) -> dict:
    return {
        "event_type": "flow",
        "src_ip": src_ip,
        "src_port": src_port,
        "dest_ip": dest_ip,
        "dest_port": dest_port,
        "proto": proto,
        "flow": {"state": "new"},
    }


def tls(*, version: str = "TLS 1.3", sni: str = "test-1.us-east-99.boltmesh.mooo.com") -> dict:
    return {
        "event_type": "tls",
        "src_ip": "192.168.1.113",
        "src_port": 40000,
        "dest_ip": NODE,
        "dest_port": 443,
        "proto": "TCP",
        "tls": {"version": version, "sni": sni, "alpn": ["h2", "http/1.1"]},
    }


def a_clean_run() -> list[dict]:
    return [
        alert(check.ENGINE_LIVE_SID, src_ip="192.168.1.113", src_port=40000,
              dest_ip=NODE, dest_port=59999, proto="UDP"),
        alert(check.HANDSHAKE_SID, src_ip="192.168.1.113", src_port=40001,
              dest_ip=NODE, dest_port=51820, proto="UDP"),
        alert(check.TRANSPORT_SID, src_ip=NODE, src_port=51820,
              dest_ip="192.168.1.113", dest_port=40002, proto="UDP"),
        alert(check.PORT_SID, src_ip="192.168.1.113", src_port=40001,
              dest_ip=NODE, dest_port=51820, proto="UDP"),
        alert(check.AWG_PORT_ADV_SID, src_ip="192.168.1.113", src_port=40003,
              dest_ip=NODE, dest_port=51821, proto="UDP"),
        tls(),
        alert(check.STREAM_TLS_ADV_SID, src_ip="192.168.1.113", src_port=40004,
              dest_ip=NODE, dest_port=443, proto="TCP"),
    ]


class AnalyzeTest(unittest.TestCase):
    def test_events_are_attributed_by_endpoint(self) -> None:
        events = a_clean_run()
        engine_live, reports = check.analyze(events, NODE, RUNGS)
        self.assertTrue(engine_live)
        self.assertEqual(reports["native"].wg_sids, [check.HANDSHAKE_SID, check.TRANSPORT_SID, check.PORT_SID])
        self.assertEqual(reports["awg"].wg_sids, [])
        self.assertEqual(reports["awg"].adversarial_sids, [check.AWG_PORT_ADV_SID])
        self.assertEqual(reports["stream"].tls_events, 1)
        self.assertEqual(reports["stream"].tls_version, "TLS 1.3")

    def test_a_control_datagram_does_not_count_as_native(self) -> None:
        # The control packet carries the handshake bytes but goes to the control
        # port; it must not make a silent native rung look detected.
        events = [
            alert(check.ENGINE_LIVE_SID, src_ip="192.168.1.113", src_port=40000,
                  dest_ip=NODE, dest_port=59999, proto="UDP"),
            alert(check.HANDSHAKE_SID, src_ip="192.168.1.113", src_port=40000,
                  dest_ip=NODE, dest_port=59999, proto="UDP"),
        ]
        _, reports = check.analyze(events, NODE, RUNGS)
        self.assertEqual(reports["native"].wg_sids, [])

    def test_the_reverse_direction_is_attributed_too(self) -> None:
        # Server -> client transport data has the node as the source; the rule
        # fires on it and it must land on the native rung, not nowhere.
        events = [
            alert(check.TRANSPORT_SID, src_ip=NODE, src_port=51820,
                  dest_ip="192.168.1.113", dest_port=40002, proto="UDP"),
        ]
        _, reports = check.analyze(events, NODE, RUNGS)
        self.assertIn(check.TRANSPORT_SID, reports["native"].wg_sids)

    def test_a_protocol_mismatch_is_ignored(self) -> None:
        # A TCP alert that happens to use the native port is not native traffic.
        events = [
            alert(check.HANDSHAKE_SID, src_ip="192.168.1.113", src_port=40000,
                  dest_ip=NODE, dest_port=51820, proto="TCP"),
        ]
        _, reports = check.analyze(events, NODE, RUNGS)
        self.assertEqual(reports["native"].wg_sids, [])

    def test_hard_tier_alerts_are_reported_not_fatal(self) -> None:
        # The harder ruleset is expected to catch awg (traffic analysis) and
        # stream (TLS); that must be reported and must not fail the run.
        events = a_clean_run() + [
            alert(9920010, src_ip="192.168.1.113", src_port=40005,
                  dest_ip=NODE, dest_port=51821, proto="UDP"),
        ]
        engine_live, reports = check.analyze(events, NODE, RUNGS)
        self.assertIn(9920010, reports["awg"].hard_sids)
        self.assertNotIn(9920010, reports["awg"].wg_sids)
        self.assertEqual(check.evaluate(engine_live, reports, True), [])

    def test_handshake_response_is_a_subject_rule(self) -> None:
        # The hardened local.rules add types 2 and 3; both must count as
        # WireGuard signatures, so an awg rung that trips one still fails.
        events = a_clean_run() + [
            alert(check.HANDSHAKE_RESPONSE_SID, src_ip=NODE, src_port=51821,
                  dest_ip="192.168.1.113", dest_port=40003, proto="UDP"),
        ]
        engine_live, reports = check.analyze(events, NODE, RUNGS)
        self.assertIn(check.HANDSHAKE_RESPONSE_SID, reports["awg"].wg_sids)
        self.assertTrue(check.evaluate(engine_live, reports, True))


class EvaluateTest(unittest.TestCase):
    def _evaluate(self, events: list[dict], expect_port_rule: bool = True) -> list[str]:
        engine_live, reports = check.analyze(events, NODE, RUNGS)
        return check.evaluate(engine_live, reports, expect_port_rule)

    def test_a_clean_run_passes(self) -> None:
        self.assertEqual(self._evaluate(a_clean_run()), [])

    def test_the_port_rule_is_only_required_when_expected(self) -> None:
        events = a_clean_run()
        without_port = [e for e in events if check.signature_id(e) != check.PORT_SID]
        self.assertEqual(self._evaluate(without_port, expect_port_rule=False), [])
        self.assertTrue(self._evaluate(without_port, expect_port_rule=True))

    def test_missing_positive_control_fails(self) -> None:
        events = [e for e in a_clean_run() if check.signature_id(e) != check.ENGINE_LIVE_SID]
        failures = self._evaluate(events)
        self.assertTrue(any(str(check.ENGINE_LIVE_SID) in f for f in failures))

    def test_native_without_a_signature_fails(self) -> None:
        events = [e for e in a_clean_run()
                  if check.signature_id(e) not in (check.HANDSHAKE_SID, check.TRANSPORT_SID)]
        failures = self._evaluate(events)
        self.assertTrue(any("native" in f for f in failures))

    def test_awg_detected_fails(self) -> None:
        events = a_clean_run() + [
            alert(check.HANDSHAKE_SID, src_ip="192.168.1.113", src_port=40003,
                  dest_ip=NODE, dest_port=51821, proto="UDP"),
        ]
        failures = self._evaluate(events)
        self.assertTrue(any("awg" in f for f in failures))

    def test_stream_detected_fails(self) -> None:
        events = a_clean_run() + [
            alert(check.TRANSPORT_SID, src_ip="192.168.1.113", src_port=40004,
                  dest_ip=NODE, dest_port=443, proto="TCP"),
        ]
        failures = self._evaluate(events)
        self.assertTrue(any("stream" in f for f in failures))

    def test_silent_awg_fails(self) -> None:
        # No AWG traffic at all: an empty signature list is not a pass.
        events = [e for e in a_clean_run()
                  if e.get("dest_port") not in (51821,) and e.get("src_port") not in (51821,)]
        failures = self._evaluate(events)
        self.assertTrue(any("awg" in f for f in failures))

    def test_silent_stream_fails(self) -> None:
        events = [e for e in a_clean_run()
                  if check.signature_id(e) != check.STREAM_TLS_ADV_SID
                  and e.get("event_type") != "tls"]
        failures = self._evaluate(events)
        self.assertTrue(any("stream" in f for f in failures))


if __name__ == "__main__":
    unittest.main(verbosity=2)
