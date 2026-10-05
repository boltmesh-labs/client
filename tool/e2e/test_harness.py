#!/usr/bin/env python3
"""Self-tests for the e2e harness's own logic, runnable without root.

The harness is a test fixture, and a broken fixture is worse than no fixture: it
reports PASS while exercising nothing. These cover the parts that can be checked on
a normal machine — the helper protocol the client speaks, and the conf and
transport spec it builds — so a mistake there surfaces without needing root, a
kernel WireGuard module, or a node.

The end-to-end run itself needs root and a running node; see run.sh.
"""

from __future__ import annotations

import base64
import importlib.util
import json
import socket
import tempfile
import threading
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent


def _load(name: str, filename: str):
    """Imports a sibling script by path, so this file stays runnable directly."""
    spec = importlib.util.spec_from_file_location(name, _HERE / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


client = _load("e2e_client", "client.py")


# --- a fake helper daemon, speaking the real protocol ---------------------


class FakeDaemon:
    """A unix-socket server that answers the helper protocol.

    It speaks the same request/response shapes as `boltmeshd`, so a client that
    cannot parse or frame a request fails these tests rather than the harness.
    """

    def __init__(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.path = str(Path(self._dir.name) / "boltmeshd.sock")
        self.caps = ["strict-validation", "caps", "stream-transport"]
        self.requests: list[dict] = []
        # Set to a (code, message) pair to make the next `up` fail.
        self.fail_up_with: tuple[str, str] | None = None
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.bind(self.path)
        self._sock.listen(4)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def close(self) -> None:
        self._sock.close()
        self._dir.cleanup()

    def _serve(self) -> None:
        while True:
            try:
                conn, _ = self._sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn: socket.socket) -> None:
        with conn, conn.makefile("rwb") as stream:
            for line in stream:
                try:
                    request = json.loads(line)
                except json.JSONDecodeError:
                    return
                self.requests.append(request)
                response = self._respond(request)
                stream.write(json.dumps(response).encode() + b"\n")
                stream.flush()

    def _respond(self, request: dict) -> dict:
        op = request.get("op")
        reply = {"v": client.PROTOCOL_VERSION, "id": request.get("id")}
        if op == "ping":
            reply["ok"] = True
            reply["caps"] = self.caps
            reply["status"] = {"interface": "wg0", "up": False, "stage": "idle"}
            return reply
        if op == "up" and self.fail_up_with:
            code, message = self.fail_up_with
            reply["ok"] = False
            reply["error"] = {"code": code, "message": message}
            return reply
        if op in ("up", "down"):
            reply["ok"] = True
            reply["status"] = {
                "interface": "wg0",
                "up": op == "up",
                "stage": "connected" if op == "up" else "disconnected",
            }
            return reply
        reply["ok"] = False
        reply["error"] = {"code": "unsupported", "message": f"unknown op {op}"}
        return reply

    def last_up(self) -> dict:
        for request in reversed(self.requests):
            if request.get("op") == "up":
                return request
        raise AssertionError("no `up` request was sent")


def b64_of_size(n: int, fill: int) -> str:
    return base64.b64encode(bytes([fill]) * n).decode()


# --- the client's helper protocol -----------------------------------------


class HelperProtocolTest(unittest.TestCase):
    def setUp(self) -> None:
        self.daemon = FakeDaemon()
        self.addCleanup(self.daemon.close)

    def test_capabilities_round_trip(self) -> None:
        with client.Helper(self.daemon.path) as helper:
            self.assertIn("stream-transport", helper.capabilities())

    def test_a_daemon_without_the_capability_is_reported_absent(self) -> None:
        # The client's ladder gates on this token, so a daemon that does not
        # advertise it must be observable as not supporting the rung.
        self.daemon.caps = ["strict-validation", "caps"]
        with client.Helper(self.daemon.path) as helper:
            self.assertNotIn("stream-transport", helper.capabilities())

    def test_request_carries_the_protocol_version_and_caps(self) -> None:
        with client.Helper(self.daemon.path) as helper:
            helper.call("ping")
        request = self.daemon.requests[-1]
        self.assertEqual(request["v"], client.PROTOCOL_VERSION)
        self.assertIn("caps", request)
        self.assertIn("strict-validation", request["caps"])

    def test_a_refusal_raises_with_the_daemons_own_code(self) -> None:
        # The daemon's code is what names *why* it refused; a generic transport
        # error would hide a bad_config from a bad port behind a timeout.
        self.daemon.fail_up_with = ("bad_config", "invalid stream spec")
        with client.Helper(self.daemon.path) as helper:
            with self.assertRaises(client.HelperError) as ctx:
                helper.call("up", config="whatever")
        self.assertEqual(ctx.exception.code, "bad_config")
        self.assertIn("invalid stream spec", ctx.exception.message)


# --- reading the dial payload ---------------------------------------------


def payload_with(*rungs: dict) -> dict:
    return {"transports": list(rungs)}


STREAM_RUNG = {
    "rung": "stream",
    "port": 443,
    "credential": {
        "server": "node.example.test:443",
        "server_name": "node.example.test",
        "spki_sha256": [b64_of_size(32, 0xAA)],
        "psk": b64_of_size(32, 0xBB),
        "client_id": b64_of_size(16, 0xCC),
    },
}
AWG_RUNG = {
    "rung": "awg",
    "port": 51821,
    "params": {
        "jc": 4, "jmin": 31, "jmax": 621,
        "s1": 36, "s2": 36, "s3": 11, "s4": 35,
        "h1": [1342177280, 1350193902],
        "h2": [1610612736, 1618846586],
        "h3": [1879048192, 1894861561],
        "h4": [2147483648, 2163863382],
    },
}


class FindTransportTest(unittest.TestCase):
    def test_it_finds_an_advertised_rung(self) -> None:
        self.assertEqual(client.find_transport(payload_with(STREAM_RUNG), "stream"),
                         STREAM_RUNG)

    def test_an_unadvertised_rung_is_absent_not_defaulted(self) -> None:
        # Absence from the list is the single meaning of "not served", so this must
        # not invent an entry: a client that treated a missing rung as a native
        # start would silently downgrade to an obfuscated node's stock device.
        self.assertIsNone(client.find_transport(payload_with(STREAM_RUNG), "awg"))

    def test_a_payload_with_no_rungs_advertises_nothing(self) -> None:
        self.assertIsNone(client.find_transport({"transports": []}, "stream"))
        self.assertIsNone(client.find_transport({}, "stream"))

    def test_it_takes_the_rung_off_the_list_not_off_the_top_level(self) -> None:
        # The old shape had a top-level `stream` object. Reading that instead of
        # the list would pin a credential to the wrong rung on a payload that
        # carries both, so the top-level key must be ignored entirely.
        payload = payload_with(STREAM_RUNG, AWG_RUNG)
        payload["stream"] = {"psk": "top-level-should-be-ignored"}
        entry = client.find_transport(payload, "stream")
        self.assertEqual(entry["credential"]["psk"], STREAM_RUNG["credential"]["psk"])


# --- the client's WireGuard config ----------------------------------------


class WgQuickConfigTest(unittest.TestCase):
    def build(self, **overrides) -> str:
        kwargs = {
            "private_key": "PRIV",
            "assigned_ip": "10.1.0.5/32",
            "server_public_key": "SRV",
            # The bridge's listen address is the peer endpoint...
            "endpoint": "127.0.0.1:51821",
            # ...and a DIFFERENT port is the interface's own.
            "listen_port": 51820,
            "allowed_ips": "10.1.0.5/32,10.1.0.1/32",
        }
        kwargs.update(overrides)
        return client.build_wg_quick_config(**kwargs)

    def test_peer_endpoint_is_the_bridge_not_the_node(self) -> None:
        # The whole rung depends on this: the bridge is what reaches the node, so
        # a conf pointing straight at the node would bypass the transport entirely
        # and silently test nothing.
        conf = self.build()
        self.assertIn("Endpoint = 127.0.0.1:51821", conf)
        self.assertNotIn("node.example.test", conf)

    def test_listen_port_is_the_deliver_port_not_the_bridge_port(self) -> None:
        # The bug this test exists for: setting ListenPort to the bridge's own
        # listen port makes the kernel try to bind a port the bridge already holds,
        # so `wg-quick up` fails on the *mtu* step with "Address already in use" —
        # an error that points nowhere near the configuration mistake.
        conf = self.build()
        self.assertIn("ListenPort = 51820", conf)
        self.assertNotIn("ListenPort = 51821", conf)

    def test_the_stream_rung_carries_no_obfuscation_directives(self) -> None:
        # The stream rung is stock even on a node that also serves the obfuscated
        # one: the node's bridge injects into its *stock* device, so a stream session
        # carries stock datagrams whatever else that node serves. client.py therefore
        # builds this conf with obfuscation=None, and this pins the consequence — an
        # AmneziaWG conf here would handshake with nobody.
        conf = self.build()
        for directive in ("Jc =", "Jmin =", "S1 =", "H1 ="):
            self.assertNotIn(directive, conf)

    def test_a_stock_region_adds_no_obfuscation_directives(self) -> None:
        # No awg rung advertised: the node runs stock WireGuard, so there is nothing
        # to carry either way.
        conf = self.build(obfuscation=None)
        for directive in ("Jc =", "Jmin =", "S1 =", "H1 ="):
            self.assertNotIn(directive, conf)

    def test_the_awg_directives_render_when_a_rung_does_carry_them(self) -> None:
        # The renderer itself, for the awg rung. The stream rung must never reach it
        # (see the test above); this keeps the formatting honest so a future rung that
        # legitimately carries parameters renders them correctly.
        conf = self.build(obfuscation={"mode": "awg", "params": AWG_RUNG["params"]})
        self.assertIn("Jc = 4", conf)
        self.assertIn("Jmin = 31", conf)
        self.assertIn("H1 = 1342177280-1350193902", conf)
        self.assertIn("H4 = 2147483648-2163863382", conf)
        self.assertIn("Endpoint = 127.0.0.1:51821", conf)
        self.assertIn("ListenPort = 51820", conf)

    def test_no_dns_line(self) -> None:
        # resolvconf talks to a resolver that does not know this tunnel's interface,
        # so a DNS line would make wg-quick fail its DNS step and tear the link down.
        self.assertNotIn("DNS", self.build())

    def test_allowed_ips_covers_only_the_overlay_addresses(self) -> None:
        # A split-tunnel AllowedIPs; the harness pings the node's tunnel address
        # specifically, so a default route would both be wrong here and make the
        # assertion meaningless.
        conf = self.build(allowed_ips="10.1.0.5/32,10.1.0.1/32")
        self.assertIn("AllowedIPs = 10.1.0.5/32,10.1.0.1/32", conf)
        self.assertNotIn("0.0.0.0/0", conf)

    def test_allowed_ips_is_not_hardcoded(self) -> None:
        # A real node lives on whatever tunnel subnet its region was provisioned
        # with, so a hardcoded subnet would leave the tunnel unroutable there — and
        # the failure looks like "the node is down", not "the conf is wrong".
        conf = self.build(assigned_ip="10.3.43.9/32",
                          allowed_ips="10.3.43.9/32,10.3.0.1/32")
        self.assertIn("AllowedIPs = 10.3.43.9/32,10.3.0.1/32", conf)
        self.assertNotIn("10.1.0", conf)


class HostRouteTest(unittest.TestCase):
    def test_a_bare_address_becomes_a_host_route(self) -> None:
        # The dial payload carries the node's tunnel address without a prefix, so
        # the /32 has to be supplied here rather than read off it.
        self.assertEqual(client.host_route("10.3.0.1"), "10.3.0.1/32")

    def test_an_existing_prefix_is_replaced_not_appended(self) -> None:
        # assigned_ip arrives as "10.1.136.173/32". Appending would give a /32/32,
        # which wg-quick rejects — and the device's own address must be routed the
        # same way as the node's regardless of which form it arrived in.
        self.assertEqual(client.host_route("10.1.136.173/32"), "10.1.136.173/32")

    def test_a_longer_prefix_is_narrowed_to_the_host(self) -> None:
        # The harness only addresses the node itself, so even a subnet-wide prefix
        # is narrowed: a subnet the harness did not derive from the payload is a
        # value that can name a different node's network than the one serving.
        self.assertEqual(client.host_route("10.1.0.1/16"), "10.1.0.1/32")

    def test_an_empty_address_is_refused(self) -> None:
        with self.assertRaises(SystemExit):
            client.host_route("/16")


class FreePortTest(unittest.TestCase):
    def test_ports_are_bindable_and_positive(self) -> None:
        port = client.free_udp_port()
        self.assertGreater(port, 0)
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.addCleanup(sock.close)
        sock.bind(("127.0.0.1", port))

    def test_two_probes_are_independent(self) -> None:
        # The client re-probes until the two differ; that only terminates if the
        # kernel does not hand back the same ephemeral port twice in a row.
        self.assertNotEqual(client.free_udp_port(), client.free_udp_port())


class ClearDevicesTest(unittest.TestCase):
    """The device-clearing step, against a stand-in for the API.

    Worth covering offline because its failure mode is invisible: a device left
    behind does not break the run that left it, it breaks the *next* one, with a
    device-limit error that names the wrong run.
    """

    def _harness(self, devices, failing: set[str] | None = None):
        """Records calls and answers with `devices`, raising for `failing` ids."""
        calls: list[tuple[str, str]] = []
        failing = failing or set()

        def fake(base, path, *, token=None, method="GET", body=None, form=None):
            calls.append((method, path))
            for bad in failing:
                if path.endswith(bad):
                    raise client.StagingError(f"HTTP 409 on {path}")
            if path == "/vpn-devices":
                return devices
            return None

        original = client._api_call
        client._api_call = fake
        self.addCleanup(setattr, client, "_api_call", original)
        return calls

    def test_deletes_every_device_after_disconnecting_it(self) -> None:
        devices = [{"id": "a", "name": "one", "platform": "linux"},
                   {"id": "b", "name": "two", "platform": "linux"}]
        calls = self._harness(devices)

        self.assertEqual(client.clear_devices("https://api", "tok"), 2)

        methods = {path: method for method, path in calls}
        # Disconnect before delete, or the backend refuses to drop a live row.
        self.assertEqual(methods["/vpn-devices/a/disconnect"], "POST")
        self.assertEqual(methods["/vpn-devices/a"], "DELETE")
        self.assertEqual(methods["/vpn-devices/b"], "DELETE")

    def test_dry_run_deletes_nothing(self) -> None:
        calls = self._harness([{"id": "a", "name": "one", "platform": "linux"}])

        self.assertEqual(client.clear_devices("https://api", "tok", dry_run=True), 1)
        self.assertEqual([c for c in calls if c[0] in ("DELETE", "POST")], [])

    def test_one_stuck_row_does_not_abandon_the_rest(self) -> None:
        # The half-cleared state is the exact one this exists to prevent, so one
        # failure must not stop the loop.
        calls = self._harness(
            [{"id": "a", "name": "one", "platform": "linux"},
             {"id": "b", "name": "two", "platform": "linux"},
             {"id": "c", "name": "three", "platform": "linux"}],
            failing={"/vpn-devices/a"},
        )

        client.clear_devices("https://api", "tok")

        deleted = {path for method, path in calls if method == "DELETE"}
        self.assertEqual(deleted, {"/vpn-devices/a", "/vpn-devices/b", "/vpn-devices/c"})

    def test_no_devices_is_not_an_error(self) -> None:
        calls = self._harness([])
        self.assertEqual(client.clear_devices("https://api", "tok"), 0)
        self.assertEqual([c for c in calls if c[0] in ("DELETE", "POST")], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
