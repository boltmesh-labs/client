#!/usr/bin/env python3
"""Self-tests for the app e2e harness's own logic, runnable without root.

The harness is a test fixture, and a broken fixture is worse than no fixture: it
reports PASS while exercising nothing. These cover the parts that can be checked on
a normal machine — the helper protocol `client.py` speaks, over both transports it
speaks it on, and the device-clearing step the runners run before the app starts.

The end-to-end run itself needs a display, a running node, and the installed
helper; see `run_linux_app.sh` / `run_windows_app.ps1`.
"""

from __future__ import annotations

import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve().parent


def _load(name: str, filename: str):
    """Imports a sibling script by path, so this file stays runnable directly."""
    spec = importlib.util.spec_from_file_location(name, _HERE / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


client = _load("e2e_client", "client.py")

_IS_WINDOWS = os.name == "nt"
needs_windows = unittest.skipUnless(_IS_WINDOWS, "a named pipe exists only on Windows")
needs_unix = unittest.skipUnless(not _IS_WINDOWS, "a unix socket exists only on Linux")


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
        self.up = False
        self.stage = "idle"
        self.rx = 0
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.bind(self.path)
        self._sock.listen(4)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    @property
    def endpoint(self) -> str:
        return self.path

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
        return respond(request, self)


@needs_windows
class FakePipeDaemon:
    """The same protocol, served over a named pipe.

    The pipe path is the one part of the app's Windows transport this repo
    cannot otherwise exercise on a Linux runner, and it is also the one part
    with its own framing code (`CreateFileW`/`ReadFile` rather than a socket),
    so a client that only ever talks to `FakeDaemon` proves nothing about
    `--pipe`. Nothing here is mocked at the protocol level: the bytes on the
    pipe are the same newline-delimited JSON the daemon speaks.
    """

    PIPE_ACCESS_DUPLEX = 0x00000003
    PIPE_TYPE_BYTE = 0x00000000
    PIPE_READMODE_BYTE = 0x00000000
    PIPE_UNLIMITED_INSTANCES = 255
    BUFFER = 64 * 1024
    INVALID_HANDLE_VALUE = -1
    # CreateNamedPipeW succeeded but the client connected before
    # ConnectNamedPipe was called, which is a connected pipe, not a failure.
    ERROR_PIPE_CONNECTED = 535

    def __init__(self) -> None:
        import ctypes
        from ctypes import wintypes

        self._ctypes = ctypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateNamedPipeW.restype = wintypes.HANDLE
        kernel32.CreateNamedPipeW.argtypes = [
            wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,
            wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
        ]
        kernel32.WriteFile.argtypes = [
            wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID,
        ]
        kernel32.ReadFile.argtypes = [
            wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID,
        ]
        self._kernel32 = kernel32

        self.name = r"\\.\pipe\boltmesh-e2e-" + uuid.uuid4().hex
        self.caps = ["strict-validation", "caps", "stream-transport"]
        self.requests: list[dict] = []
        self.fail_with: tuple[str, str] | None = None
        self.up = False
        self.stage = "idle"
        self.rx = 0
        # The harness makes one request per connection, so the pipe has to
        # answer more than once over a run - the same unlimited-instances
        # behaviour the daemon's own listener has.
        self._pipe = self._create_instance()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    @property
    def endpoint(self) -> str:
        return self.name

    def close(self) -> None:
        # The serving thread blocks in ConnectNamedPipe on a fresh instance,
        # which a daemon thread abandons at process exit; closing the pipe it
        # is *not* waiting on would only race it.
        try:
            self._kernel32.CloseHandle(self._pipe)
        except OSError:
            pass

    def _create_instance(self) -> int:
        handle = self._kernel32.CreateNamedPipeW(
            self.name, self.PIPE_ACCESS_DUPLEX,
            self.PIPE_TYPE_BYTE | self.PIPE_READMODE_BYTE,
            self.PIPE_UNLIMITED_INSTANCES, self.BUFFER, self.BUFFER, 0, None,
        )
        if handle == self.INVALID_HANDLE_VALUE:
            raise OSError(f"CreateNamedPipeW failed: {self._ctypes.get_last_error()}")
        return handle

    def _serve(self) -> None:
        handle = self._pipe
        try:
            while True:
                if not self._kernel32.ConnectNamedPipe(handle, None):
                    if self._ctypes.get_last_error() != self.ERROR_PIPE_CONNECTED:
                        return
                try:
                    self._exchange(handle)
                finally:
                    self._kernel32.DisconnectNamedPipe(handle)
                    self._kernel32.CloseHandle(handle)
                # One more instance, so the next request can connect while this
                # one's replies have already been read.
                handle = self._create_instance()
        except Exception:  # noqa: BLE001 - a daemon thread's death is its own
            return

    def _readline(self, handle: int) -> bytes:
        buf = b""
        while b"\n" not in buf:
            chunk = self._read(handle, self.BUFFER)
            if not chunk:
                return buf
            buf += chunk
        return buf.split(b"\n", 1)[0]

    def _read(self, handle: int, size: int) -> bytes:
        read = self._ctypes.wintypes.DWORD()
        buf = self._ctypes.create_string_buffer(size)
        if not self._kernel32.ReadFile(
            handle, buf, size, self._ctypes.byref(read), None
        ):
            return b""
        return buf.raw[: read.value]

    def _write(self, handle: int, data: bytes) -> None:
        written = self._ctypes.wintypes.DWORD()
        buf = self._ctypes.create_string_buffer(data)
        self._kernel32.WriteFile(
            handle, buf, len(data), self._ctypes.byref(written), None
        )

    def _exchange(self, handle: int) -> None:
        while True:
            line = self._readline(handle)
            if not line:
                # The client closed after its one request, which is the whole
                # exchange the app's transport makes.
                return
            request = json.loads(line)
            self.requests.append(request)
            self._write(handle, json.dumps(respond(request, self)).encode() + b"\n")


def respond(request: dict, daemon: Any) -> dict:
    """The daemon's reply to one request, shared by both transports."""
    op = request.get("op")
    reply = {"v": client.PROTOCOL_VERSION, "id": request.get("id")}
    if daemon.fail_with is not None:
        code, message = daemon.fail_with
        daemon.fail_with = None
        reply["ok"] = False
        reply["error"] = {"code": code, "message": message}
        return reply
    if op == "ping":
        reply["ok"] = True
        reply["caps"] = daemon.caps
        reply["status"] = _status(daemon)
        return reply
    if op in ("up", "down"):
        # The tunnel's own state, so a `status` read afterwards is a real read
        # rather than a canned reply.
        daemon.up = op == "up"
        daemon.stage = "connected" if daemon.up else "disconnected"
        reply["ok"] = True
        reply["status"] = _status(daemon)
        return reply
    if op == "status":
        reply["ok"] = True
        reply["status"] = _status(daemon)
        return reply
    reply["ok"] = False
    reply["error"] = {"code": "unsupported", "message": f"unknown op {op}"}
    return reply


def _status(daemon: Any) -> dict:
    """The daemon's view of the tunnel, in the shape `protocol.Status` serialises."""
    return {
        "interface": "boltmesh0",
        "up": daemon.up,
        "stage": daemon.stage,
        "rxBytes": daemon.rx,
        "txBytes": 0,
    }


# --- the client's helper protocol -----------------------------------------


class HelperProtocolTests:
    """The protocol assertions, run against whichever transport the daemon uses."""

    # Replaced per transport: the unix socket on Linux, the pipe on Windows.
    daemon_factory = FakeDaemon

    def setUp(self) -> None:
        self.daemon = self.daemon_factory()
        self.addCleanup(self.daemon.close)

    def test_capabilities_round_trip(self) -> None:
        with client.Helper(self.daemon.endpoint) as helper:
            self.assertIn("stream-transport", helper.capabilities())

    def test_a_daemon_without_the_capability_is_reported_absent(self) -> None:
        # The client's ladder gates on this token, so a daemon that does not
        # advertise it must be observable as not supporting the rung.
        self.daemon.caps = ["strict-validation", "caps"]
        with client.Helper(self.daemon.endpoint) as helper:
            self.assertNotIn("stream-transport", helper.capabilities())

    def test_request_carries_the_protocol_version_and_caps(self) -> None:
        with client.Helper(self.daemon.endpoint) as helper:
            helper.call("ping")
        request = self.daemon.requests[-1]
        self.assertEqual(request["v"], client.PROTOCOL_VERSION)
        self.assertIn("caps", request)
        self.assertIn("strict-validation", request["caps"])

    def test_a_refusal_raises_with_the_daemons_own_code(self) -> None:
        # The daemon's code is what names *why* it refused; a generic transport
        # error would hide a named failure behind a timeout.
        self.daemon.fail_with = ("bad_config", "invalid config")
        with client.Helper(self.daemon.endpoint) as helper:
            with self.assertRaises(client.HelperError) as ctx:
                helper.call("down")
        self.assertEqual(ctx.exception.code, "bad_config")
        self.assertIn("invalid config", ctx.exception.message)

    def test_a_status_read_frames_the_reply(self) -> None:
        # One request per connection, so the framing has to survive a second
        # request over a fresh connection too.
        with client.Helper(self.daemon.endpoint) as helper:
            helper.call("up")
        with client.Helper(self.daemon.endpoint) as helper:
            status = helper.call("status")
        self.assertEqual(status["status"]["interface"], "boltmesh0")
        self.assertTrue(status["status"]["up"])
        self.assertEqual(status["status"]["stage"], "connected")


@needs_unix
class UnixHelperProtocolTest(HelperProtocolTests, unittest.TestCase):
    """The protocol assertions, over the unix socket."""


@needs_windows
class PipeHelperProtocolTest(HelperProtocolTests, unittest.TestCase):
    """The protocol assertions, over the named pipe."""

    daemon_factory = FakePipeDaemon


class TransportSelectionTest(unittest.TestCase):
    """Endpoint selection: a socket path is a socket, a `\\...` path is a pipe."""

    def test_a_pipe_path_selects_the_pipe_transport(self) -> None:
        # The endpoint chooses the transport on every host: no platform branch,
        # so the runner on either side passes the same shape of flag.
        self.assertTrue(client._is_pipe(r"\\.\pipe\boltmesh\boltmeshd"))
        self.assertFalse(client._is_pipe("/run/boltmesh/boltmeshd.sock"))

    @needs_unix
    def test_a_unix_socket_path_opens_the_unix_transport(self) -> None:
        # A daemon to really open, so the test never depends on this machine
        # having the helper installed.
        daemon = FakeDaemon()
        self.addCleanup(daemon.close)
        conn = client._connect(daemon.path)
        self.addCleanup(conn.close)
        self.assertIsInstance(conn, client._UnixConn)
        self.assertNotIsInstance(conn, client._PipeConn)

    @needs_windows
    def test_a_pipe_path_opens_the_pipe_transport(self) -> None:
        conn = client._connect(r"\\.\pipe\boltmesh\boltmeshd")
        self.addCleanup(conn.close)
        self.assertIsInstance(conn, client._PipeConn)

    def test_a_missing_endpoint_is_a_named_unavailable(self) -> None:
        # A teardown that finds no helper must name "unavailable", not crash:
        # it is the addTearDown path after a run that died before the tunnel.
        with self.assertRaises(client.HelperError) as ctx:
            client.Helper(_missing_endpoint())
        self.assertEqual(ctx.exception.code, "unavailable")

    def test_down_without_a_helper_is_not_a_failure(self) -> None:
        # The exit status is what the Dart teardown net ignores, so it must be
        # 0 for the same reason: "nothing to tear down" is the desired end state.
        endpoint = _missing_endpoint()
        result = subprocess.run(
            [sys.executable, str(_HERE / "client.py"), _flag(endpoint),
             endpoint, "--down"],
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already down", result.stdout)


def _missing_endpoint() -> str:
    """An endpoint nothing is listening on, for this platform."""
    if _IS_WINDOWS:
        return r"\\.\pipe\boltmesh-e2e-" + uuid.uuid4().hex
    return "/nonexistent/boltmeshd.sock"


def _flag(endpoint: str) -> str:
    return "--pipe" if endpoint.startswith("\\\\") else "--socket"


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


class LinuxFirewallHelperValidationTest(unittest.TestCase):
    """The root helper rejects malformed tuples before requiring elevation."""

    def _run(self, address: str, port: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(_HERE / "firewall_linux.sh"), "block", address, port],
            capture_output=True,
            text=True,
            timeout=10,
        )

    @unittest.skipIf(_IS_WINDOWS, "the Linux helper is a bash script")
    def test_rejects_a_non_ip_endpoint(self) -> None:
        result = self._run("example.invalid", "51820")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("must run as root", result.stderr)

    @unittest.skipIf(_IS_WINDOWS, "the Linux helper is a bash script")
    def test_rejects_an_out_of_range_port(self) -> None:
        result = self._run("192.0.2.1", "65536")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("must run as root", result.stderr)


class WindowsScriptTest(unittest.TestCase):
    """Guards the Windows runner scripts against a PowerShell trap.

    `\"\"\"text\"\"\"` is a docstring in Python but a *bare string expression* in
    PowerShell: its value joins the enclosing function's output, so a function
    that looks like it returns a parsed table returns that string first, and
    the caller reads a nonsense value from a script that looks correct. It has
    already cost a debugging round here - `run_windows_app.ps1` decided `.env`
    set no API_BASE_URL, on the one host where the script can actually run - so
    it is worth a static look before that round is repeated.
    """

    def test_no_python_style_docstrings(self) -> None:
        offenders = []
        for script in sorted(_HERE.glob("*.ps1")):
            for number, line in enumerate(
                script.read_text(encoding="utf-8").splitlines(), start=1
            ):
                stripped = line.strip()
                if stripped.startswith('"""') or stripped.startswith("'''"):
                    offenders.append(f"{script.name}:{number}: {stripped[:60]}")
        self.assertEqual(
            offenders,
            [],
            "a Python-style docstring in PowerShell is emitted into the "
            "function's return value; use # comments instead",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
