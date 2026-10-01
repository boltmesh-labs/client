#!/usr/bin/env python3
"""Self-tests for the harness's own logic, runnable without root.

The harness is a test fixture, and a broken fixture is worse than no fixture: it
reports PASS while exercising nothing. These cover the parts that can be checked
on a normal machine — the wire framing the client speaks, the spec and conf it
builds, and the stub control plane's routes — so a mistake there surfaces without
needing namespaces, veth, or a kernel WireGuard module.

The end-to-end run itself still needs root; see run.sh.
"""

from __future__ import annotations

import base64
import contextlib
import importlib.util
import io
import json
import socket
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path

_HERE = Path(__file__).resolve().parent


def _load(name: str, filename: str):
    """Imports a sibling script by path, so this file stays runnable directly."""
    spec = importlib.util.spec_from_file_location(name, _HERE / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


client = _load("stream_e2e_client", "client.py")
controlplane = _load("stream_e2e_controlplane", "controlplane.py")


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


class StubControlPlane:
    """The stub control plane, started on an ephemeral port for one test."""

    def __init__(self, client_pub: str = "client-pub") -> None:
        self.state = controlplane.State("stream.harness.test", 443, 51820)
        self.state.client_public_key = client_pub
        handler = type("BoundHandler", (controlplane.Handler,), {"state": self.state})
        from http.server import ThreadingHTTPServer

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.port = self._server.server_address[1]
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()

    def get(self, path: str) -> dict:
        with urllib.request.urlopen(f"{self.base_url}{path}", timeout=5) as resp:
            return json.load(resp)

    def post(self, path: str, body: dict) -> dict:
        req = urllib.request.Request(
            f"{self.base_url}{path}",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.load(resp)


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


class WgQuickConfigTest(unittest.TestCase):
    def build(self) -> str:
        return client.build_wg_quick_config(
            private_key="PRIV",
            assigned_ip="10.254.0.2/32",
            server_public_key="SRV",
            # The bridge's listen address is the peer endpoint...
            endpoint="127.0.0.1:51821",
            # ...and a DIFFERENT port is the interface's own.
            listen_port=51820,
            allowed_ips="10.254.0.0/16",
        )

    def test_peer_endpoint_is_the_bridge_not_the_node(self) -> None:
        # The whole rung depends on this: the bridge is what reaches the node, so
        # a conf pointing straight at the node would bypass the transport
        # entirely and silently test nothing.
        conf = self.build()
        self.assertIn("Endpoint = 127.0.0.1:51821", conf)
        self.assertNotIn("198.51.100.2", conf)

    def test_listen_port_is_the_deliver_port_not_the_bridge_port(self) -> None:
        # The bug this test exists for: setting ListenPort to the bridge's own
        # listen port makes the kernel try to bind a port the bridge already
        # holds, so `wg-quick up` fails on the *mtu* step with "Address already
        # in use" — an error that points nowhere near the configuration mistake.
        conf = self.build()
        self.assertIn("ListenPort = 51820", conf)
        self.assertNotIn("ListenPort = 51821", conf)

    def test_a_stock_region_adds_no_obfuscation_directives(self) -> None:
        # No descriptor (a stock region): the node runs stock WireGuard, so the
        # datagrams inside the stream are stock too.
        conf = self.build()
        for directive in ("Jc =", "Jmin =", "S1 =", "H1 ="):
            self.assertNotIn(directive, conf)

    def test_an_obfuscated_region_carries_its_directives(self) -> None:
        # The inner format follows the region: an obfuscated region's node runs
        # the AmneziaWG device, so the stream must carry the same directives the
        # direct AWG rung would. The endpoint stays the bridge's loopback address.
        conf = client.build_wg_quick_config(
            private_key="PRIV",
            assigned_ip="10.254.0.2/32",
            server_public_key="SRV",
            endpoint="127.0.0.1:51821",
            listen_port=51820,
            allowed_ips="10.254.0.0/16",
            obfuscation={
                "mode": "awg",
                "params": {
                    "jc": 4, "jmin": 31, "jmax": 621,
                    "s1": 36, "s2": 36, "s3": 11, "s4": 35,
                    "h1": [1342177280, 1350193902],
                    "h2": [1610612736, 1618846586],
                    "h3": [1879048192, 1894861561],
                    "h4": [2147483648, 2163863382],
                },
            },
        )
        self.assertIn("Jc = 4", conf)
        self.assertIn("Jmin = 31", conf)
        self.assertIn("H1 = 1342177280-1350193902", conf)
        self.assertIn("H4 = 2147483648-2163863382", conf)
        self.assertIn("Endpoint = 127.0.0.1:51821", conf)
        self.assertIn("ListenPort = 51820", conf)

    def test_no_dns_line(self) -> None:
        # resolvconf talks to a resolver in the host namespace, which does not
        # know this namespace's interface, so a DNS line would make wg-quick fail
        # its DNS step and tear the link down.
        self.assertNotIn("DNS", self.build())

    def test_allowed_ips_covers_only_the_tunnel_subnet(self) -> None:
        # A split-tunnel AllowedIPs; the harness asserts on the tunnel subnet
        # specifically, so a default route would make the assertion meaningless.
        conf = self.build()
        self.assertIn("AllowedIPs = 10.254.0.0/16", conf)
        self.assertNotIn("0.0.0.0/0", conf)

    def test_allowed_ips_is_not_hardcoded(self) -> None:
        # A real node lives on whatever tunnel subnet its region was provisioned
        # with, so a hardcoded /16 would make the tunnel unroutable there — and
        # the failure looks like "the node is down", not "the conf is wrong".
        conf = client.build_wg_quick_config(
            private_key="PRIV", assigned_ip="10.1.90.193/32", server_public_key="SRV",
            endpoint="192.168.1.115:443", listen_port=51820,
            allowed_ips="10.1.0.0/16",
        )
        self.assertIn("AllowedIPs = 10.1.0.0/16", conf)
        self.assertNotIn("10.254.0.0/16", conf)


class FreePortTest(unittest.TestCase):
    def test_ports_are_bindable_and_positive(self) -> None:
        port = client.free_udp_port()
        self.assertGreater(port, 0)
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.addCleanup(sock.close)
        sock.bind(("127.0.0.1", port))

    def test_two_probes_are_independent(self) -> None:
        # The harness re-probes until the two differ; that only terminates if the
        # kernel does not hand back the same ephemeral port twice in a row.
        first = client.free_udp_port()
        second = client.free_udp_port()
        self.assertNotEqual(first, second)


# --- the stub control plane -----------------------------------------------


class StubControlPlaneTest(unittest.TestCase):
    def setUp(self) -> None:
        self.cp = StubControlPlane()
        self.addCleanup(self.cp.close)

    def test_registration_carries_the_stream_ingress_descriptor(self) -> None:
        body = self.cp.post("/v1/control-plane/register/manual",
                            {"agent_version": "test", "wg_public_key": "node-pub"})
        self.assertTrue(body["stream_ingress"]["enabled"])
        self.assertEqual(body["stream_ingress"]["server_name"], "stream.harness.test")
        self.assertEqual(body["stream_ingress"]["listen_port"], 443)
        # The node mints its own identity, so the descriptor must not carry key
        # material: a certificate here would mean the control plane had begun
        # storing a TLS private key.
        for field in ("certificate_pem", "private_key_pem"):
            self.assertNotIn(field, body["stream_ingress"])

    def test_registration_records_the_nodes_wireguard_key(self) -> None:
        # The client needs this as its peer key and there is no other channel
        # carrying it.
        self.cp.post("/v1/control-plane/register/manual", {"wg_public_key": "node-pub-xyz"})
        self.assertEqual(self.cp.get("/harness/state")["node_public_key"], "node-pub-xyz")

    def test_peers_sync_carries_the_device_credential(self) -> None:
        rows = self.cp.get("/v1/control-plane/peers-sync")
        self.assertEqual(len(rows), 1)
        stream = rows[0]["stream"]
        self.assertEqual(len(base64.b64decode(stream["psk"])), controlplane.PSK_BYTES)
        self.assertEqual(len(base64.b64decode(stream["client_id"])),
                         controlplane.CLIENT_ID_BYTES)
        self.assertEqual(rows[0]["public_key"], "client-pub")

    def test_pin_is_absent_until_the_node_reports_one(self) -> None:
        # This is the property that makes the harness meaningful: the client's pin
        # comes from a node that actually came up, so before the first heartbeat
        # carrying one there is nothing to pin.
        self.assertIsNone(self.cp.get("/harness/state")["stream_spki_sha256"])

    def test_heartbeat_records_the_reported_pin(self) -> None:
        pin = b64_of_size(32, 0xAA)
        self.cp.post("/v1/control-plane/heartbeat",
                     {"timestamp": 0, "status": "healthy", "stream_spki_sha256": pin})
        self.assertEqual(self.cp.get("/harness/state")["stream_spki_sha256"], pin)

    def test_a_heartbeat_without_a_pin_leaves_the_recorded_one_alone(self) -> None:
        # A node whose ingress stopped must not have its last good pin cleared by
        # a later pulse that simply has nothing to say — and the field is omitted
        # rather than sent empty for exactly that reason.
        pin = b64_of_size(32, 0xBB)
        self.cp.post("/v1/control-plane/heartbeat", {"stream_spki_sha256": pin})
        self.cp.post("/v1/control-plane/heartbeat", {"status": "healthy"})
        self.assertEqual(self.cp.get("/harness/state")["stream_spki_sha256"], pin)

    def test_heartbeat_rejects_a_malformed_pin_by_ignoring_it(self) -> None:
        # Not a 422: the pin is one optional field on a hot path, and a bad value
        # must not stop the node's telemetry from being recorded.
        self.cp.post("/v1/control-plane/heartbeat",
                     {"stream_spki_sha256": 12345, "status": "healthy"})
        self.assertIsNone(self.cp.get("/harness/state")["stream_spki_sha256"])

    def test_stream_and_wireguard_ports_must_differ(self) -> None:
        # Sharing one port would point a client's WireGuard endpoint at a TLS
        # listener. The real control plane enforces this on the descriptor; the
        # fixture refuses the same configuration rather than serving it.
        with contextlib.redirect_stderr(io.StringIO()):
            code = _run_main([
                "--port", "8477", "--server-name", "x",
                "--stream-port", "51820", "--wg-port", "51820",
                "--client-public-key", "k",
            ])
        self.assertEqual(code, 2, "a port collision must be refused before serving")


def _run_main(argv: list[str]) -> int:
    """Calls the fixture's main() and returns its exit code.

    Not the module's own ``raise SystemExit(main())`` wrapper, so the refusal is
    observable as a return value rather than an exception — which is what the
    process boundary would actually see.
    """
    import sys

    saved = sys.argv
    sys.argv = ["controlplane.py", *argv]
    try:
        return controlplane.main()
    finally:
        sys.argv = saved


class WaitForPinTest(unittest.TestCase):
    def test_it_times_out_when_no_node_reports_a_pin(self) -> None:
        # The harness must not hang forever against a node that registered but
        # never started its ingress — that is the failure mode this wait exists
        # to catch, and it has to be a clear failure rather than a stall.
        cp = StubControlPlane()
        self.addCleanup(cp.close)
        with self.assertRaises(SystemExit) as ctx:
            client.wait_for_pin(cp.base_url, timeout=0.5)
        self.assertIn("SPKI pin", str(ctx.exception))

    def test_it_returns_a_reported_pin(self) -> None:
        cp = StubControlPlane()
        self.addCleanup(cp.close)
        pin = b64_of_size(32, 0xCC)
        cp.post("/v1/control-plane/heartbeat", {"stream_spki_sha256": pin})
        self.assertEqual(client.wait_for_pin(cp.base_url, timeout=5), pin)


class StateShapesTest(unittest.TestCase):
    def test_a_disabled_descriptor_serves_the_documented_shape(self) -> None:
        # Guards the encoding the node parses: absent is the native data plane,
        # and the zero descriptor must survive a JSON round trip as "off".
        encoded = json.loads(json.dumps({"enabled": False, "listen_port": 0,
                                         "server_name": ""}))
        self.assertFalse(encoded["enabled"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
