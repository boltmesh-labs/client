#!/usr/bin/env python3
"""Self-tests for the app e2e harness's own logic, runnable without root.

The harness is a test fixture, and a broken fixture is worse than no fixture: it
reports PASS while exercising nothing. These cover the parts that can be checked on
a normal machine — the helper protocol `client.py` speaks, and the device-clearing
step `run_linux_app.sh` runs before the app starts.

The end-to-end run itself needs a display, a running node, and the installed
helper; see `run_linux_app.sh`.
"""

from __future__ import annotations

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
        # Set to a (code, message) pair to make the next call fail.
        self.fail_with: tuple[str, str] | None = None
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
        if self.fail_with is not None:
            code, message = self.fail_with
            self.fail_with = None
            reply["ok"] = False
            reply["error"] = {"code": code, "message": message}
            return reply
        if op == "ping":
            reply["ok"] = True
            reply["caps"] = self.caps
            reply["status"] = {"interface": "boltmesh0", "up": False, "stage": "idle"}
            return reply
        if op in ("up", "down"):
            reply["ok"] = True
            reply["status"] = {
                "interface": "boltmesh0",
                "up": op == "up",
                "stage": "connected" if op == "up" else "disconnected",
            }
            return reply
        reply["ok"] = False
        reply["error"] = {"code": "unsupported", "message": f"unknown op {op}"}
        return reply


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
        # error would hide a named failure behind a timeout.
        self.daemon.fail_with = ("bad_config", "invalid config")
        with client.Helper(self.daemon.path) as helper:
            with self.assertRaises(client.HelperError) as ctx:
                helper.call("down")
        self.assertEqual(ctx.exception.code, "bad_config")
        self.assertIn("invalid config", ctx.exception.message)


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
