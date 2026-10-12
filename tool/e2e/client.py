#!/usr/bin/env python3
"""Helper-transport utilities for the app e2e harness.

The end-to-end run itself is the desktop app under
`integration_test/app_e2e.dart`, driven by `run_linux_app.sh` /
`run_windows_app.ps1`. This script is the utility those runners wrap: it clears
the account's devices before the app starts, so a run that failed part-way
cannot leave a device row that makes the next run report a device limit, and it
tears a live tunnel down from a test's `addTearDown` net, which runs after the
widget tree and its provider container are gone.

It speaks the same newline-delimited JSON request/response protocol that
`lib/features/vpn/data/helper_client.dart` speaks, over the same transport the
app dials — the Unix socket on Linux, the named pipe on Windows — so what is
exercised is the real daemon over its real transport rather than a test double.

`--down` and `--status` need nothing but the transport, so teardown and status
reads cannot fail merely because the API or the node has gone away.
"""

from __future__ import annotations

import argparse
import json
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

PROTOCOL_VERSION = 1
CAPS = ["strict-validation", "caps", "stream-transport"]


class HelperError(RuntimeError):
    """The helper refused an operation.

    Carries the daemon's own code so a failure names *why* the daemon refused
    rather than surfacing as a generic transport error.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


class StagingError(RuntimeError):
    """The real control plane refused a request."""


class Helper:
    """One connection to boltmeshd, one request per call.

    The endpoint is either a Unix socket path (Linux) or a named pipe
    (Windows); both carry the same newline-delimited JSON, which is the point of
    the app's own transport seam having two implementations.
    """

    def __init__(self, endpoint: str) -> None:
        self._conn = _connect(endpoint)
        self._buf = b""
        self._seq = 0

    def close(self) -> None:
        try:
            self._conn.close()
        except OSError:
            pass

    def __enter__(self) -> "Helper":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def _readline(self) -> bytes:
        while b"\n" not in self._buf:
            chunk = self._conn.recv(65536)
            if not chunk:
                raise HelperError("eof", "the helper closed the connection")
            self._buf += chunk
        line, _, self._buf = self._buf.partition(b"\n")
        return line

    def call(self, op: str, **fields: Any) -> dict[str, Any]:
        """Sends one request and returns the response, raising on refusal."""
        self._seq += 1
        request = {"v": PROTOCOL_VERSION, "id": str(self._seq), "op": op, "caps": CAPS}
        request.update(fields)
        self._conn.sendall(json.dumps(request).encode("utf-8") + b"\n")

        response = json.loads(self._readline())
        if not response.get("ok"):
            err = response.get("error") or {}
            raise HelperError(err.get("code", "unknown"), err.get("message", "no message"))
        return response

    def capabilities(self) -> list[str]:
        return self.call("ping").get("caps", [])


# --- transports ------------------------------------------------------------


class _UnixConn:
    """One Unix-socket connection to the helper."""

    def __init__(self, path: str) -> None:
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self._sock.connect(path)
        except OSError as exc:
            self._sock.close()
            raise HelperError("unavailable", f"helper socket unavailable: {exc}") from None

    def sendall(self, data: bytes) -> None:
        self._sock.sendall(data)

    def recv(self, size: int) -> bytes:
        return self._sock.recv(size)

    def close(self) -> None:
        try:
            self._sock.close()
        except OSError:
            pass


class _PipeConn:
    """One named-pipe connection to the helper, through ctypes.

    `dart:io` has no Windows named-pipe client either — the Flutter app proxies
    the same exchange through `windows/runner/helper_pipe_io.cpp` — so this speaks
    CreateFileW/WriteFile/ReadFile directly. Stdlib only: a pywin32 dependency
    for one framed exchange would be a worse trade than thirty lines of ctypes.
    """

    GENERIC_READ = 0x80000000
    GENERIC_WRITE = 0x40000000
    OPEN_EXISTING = 3
    # CreateFileW reports failure by returning -1, which ctypes hands back as
    # the unsigned 64-bit handle value; NULL is the other failure form.
    INVALID_HANDLE_VALUE = 0xFFFFFFFFFFFFFFFF

    def __init__(self, name: str) -> None:
        import ctypes
        from ctypes import wintypes

        self._ctypes = ctypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateFileW.restype = wintypes.HANDLE
        kernel32.CreateFileW.argtypes = [
            wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
            wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
        ]
        kernel32.WriteFile.argtypes = [
            wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID,
        ]
        kernel32.ReadFile.argtypes = [
            wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID,
        ]
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        self._kernel32 = kernel32

        # The pipe exists only while the daemon's service runs, so a connect
        # right after an install or a restart can race it. WaitNamedPipe waits
        # for the name to appear, so the race costs at most one wait rather
        # than a nameless "the helper is not there".
        kernel32.WaitNamedPipeW(name, 5000)
        handle = kernel32.CreateFileW(
            name, self.GENERIC_READ | self.GENERIC_WRITE, 0, None,
            self.OPEN_EXISTING, 0, None,
        )
        if handle is None or handle == self.INVALID_HANDLE_VALUE:
            err = ctypes.get_last_error()
            raise HelperError(
                "unavailable", f"helper pipe {name} unavailable: error {err}"
            ) from None
        self._handle = handle

    def sendall(self, data: bytes) -> None:
        written = self._ctypes.wintypes.DWORD()
        buf = self._ctypes.create_string_buffer(data)
        if not self._kernel32.WriteFile(
            self._handle, buf, len(data), self._ctypes.byref(written), None
        ):
            raise HelperError("unavailable", "the helper pipe write failed")
        if written.value != len(data):
            raise HelperError("unavailable", "the helper pipe write was short")

    def recv(self, size: int) -> bytes:
        read = self._ctypes.wintypes.DWORD()
        buf = self._ctypes.create_string_buffer(size)
        if not self._kernel32.ReadFile(
            self._handle, buf, size, self._ctypes.byref(read), None
        ):
            raise HelperError("unavailable", "the helper pipe read failed")
        return buf.raw[: read.value]

    def close(self) -> None:
        try:
            self._kernel32.CloseHandle(self._handle)
        except OSError:
            pass


def _is_pipe(endpoint: str) -> bool:
    r"""True when [endpoint] names a named pipe rather than a unix socket.

    A named pipe path always starts with a UNC prefix (`\\.\pipe\...`), which no
    filesystem path does, so the endpoint names its own transport.
    """
    return endpoint.startswith("\\\\")


def _connect(endpoint: str) -> _UnixConn | _PipeConn:
    """Opens the transport [endpoint] names: a pipe on Windows, a unix socket else."""
    if _is_pipe(endpoint):
        return _PipeConn(endpoint)
    return _UnixConn(endpoint)


# --- the API ----------------------------------------------------------------


def _api_call(base: str, path: str, *, token: str | None = None, method: str = "GET",
              body: dict | None = None, form: dict | None = None) -> object:
    """One authenticated JSON call, retrying only what is worth retrying.

    The real API rate-limits even `/auth/login`, so a harness that cannot back off
    cannot run against it at all. The same is true of the gateway in front of it:
    a 502/503/504 is the proxy failing to reach the app, not the app answering,
    and it clears on its own. Both are retried; every other status is a real
    answer and propagates, so a genuinely wrong request still fails fast instead
    of being retried into a slower failure.
    """
    headers = {"Accept": "application/json"}
    data = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"

    for attempt in range(6):
        req = urllib.request.Request(f"{base.rstrip('/')}{path}", data=data,
                                     headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as exc:
            payload = exc.read().decode("utf-8", "replace")
            transient = exc.code == 429 or exc.code in (502, 503, 504)
            if transient and attempt < 5:
                delay = 5 * (attempt + 1)
                why = "rate limited" if exc.code == 429 else f"gateway {exc.code}"
                print(f"  {why} on {path}; retrying in {delay}s", flush=True)
                time.sleep(delay)
                continue
            raise StagingError(f"HTTP {exc.code} on {path}: {payload[:300]}") from None
        except urllib.error.URLError as exc:
            raise StagingError(f"{path}: {exc.reason}") from None
    raise AssertionError("unreachable")


def login(base: str, user: str, password: str) -> str:
    """The login route is form-encoded, not JSON: an OAuth2 password grant."""
    result = _api_call(base, "/auth/login", method="POST", form={
        "grant_type": "password", "username": user, "password": password,
        "remember_me": "true",
    })
    token = result.get("access_token") if isinstance(result, dict) else None
    if not token:
        raise StagingError("login succeeded but returned no access_token")
    return token


def clear_devices(base: str, token: str, *, dry_run: bool = False) -> int:
    """Deletes every device on the account, so a run starts from a known count.

    The subscription caps how many devices can be active, and a run that fails
    part-way leaves its device behind: the interface is gone but the row is not,
    so the *next* run cannot provision. That is a bad way to fail -- the run
    that broke is long gone and the one reporting the limit never touched it --
    so the count is reset up front instead.

    Destructive by design, which is why it names every row before removing it
    and takes --dry-run.
    """
    devices = _api_call(base, "/vpn-devices", token=token) or []
    rows = devices.get("data", devices) if isinstance(devices, dict) else devices
    if not rows:
        print("no devices to clear", flush=True)
        return 0

    print(f"{len(rows)} device(s) on the account:", flush=True)
    for row in rows:
        print(f"  {row.get('id')}  {row.get('name')}  ({row.get('platform')})",
              flush=True)
    if dry_run:
        print("dry run: nothing deleted", flush=True)
        return len(rows)

    for row in rows:
        device_id = row.get("id")
        if not device_id:
            continue
        try:
            # Disconnect first where the harness can: the server refuses to drop
            # a row that still has a live tunnel bound to it.
            try:
                _api_call(base, f"/vpn-devices/{device_id}/disconnect",
                          token=token, method="POST")
            except StagingError as exc:
                print(f"  {device_id}: disconnect reported {exc}; deleting anyway",
                      flush=True)
            _api_call(base, f"/vpn-devices/{device_id}", token=token,
                      method="DELETE")
            print(f"  deleted {device_id}", flush=True)
        except StagingError as exc:
            # One stuck row must not leave the rest behind: that is the exact
            # half-cleared state this function exists to prevent.
            print(f"  {device_id}: {exc}", flush=True)
    return len(rows)


# --- entry point -----------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--socket", help="boltmeshd's unix socket path (Linux)")
    ap.add_argument("--pipe", help="boltmeshd's named pipe path (Windows)")
    ap.add_argument("--api-user", help="API user")
    ap.add_argument("--api-password", help="API password")
    ap.add_argument("--api-base", help="API base URL, for the modes that read no helper")

    ap.add_argument("--down", action="store_true",
                    help="tear the tunnel down and exit. Needs only --socket or --pipe")
    ap.add_argument("--status", action="store_true",
                    help="print the daemon's own view of the tunnel and exit. The "
                         "kernel's `wg show` cannot read a userspace AmneziaWG device, "
                         "so this is the equivalent read when the region is obfuscated "
                         "or the host is Windows. Needs only --socket or --pipe")
    ap.add_argument("--clear-devices", action="store_true",
                    help="delete every device on the account and exit, so a run starts "
                         "from a known count. A run that fails part-way leaves its "
                         "device behind and the next one cannot provision. Destructive: "
                         "this is a lab harness, not something to point at a real account")
    ap.add_argument("--dry-run", action="store_true",
                    help="with --clear-devices, list what would be deleted and stop")
    args = ap.parse_args()

    if args.clear_devices:
        missing = [flag for flag, value in (
            ("--api-base", args.api_base),
            ("--api-user", args.api_user),
            ("--api-password", args.api_password),
        ) if not value]
        if missing:
            ap.error("--clear-devices requires: " + ", ".join(missing))
        base = args.api_base
        clear_devices(base, login(base, args.api_user, args.api_password),
                      dry_run=args.dry_run)
        return 0

    if args.socket and args.pipe:
        ap.error("pass --socket or --pipe, not both; they are the same transport "
                 "on different platforms")
    endpoint = args.pipe or args.socket
    if not endpoint:
        ap.error("--socket (Linux) or --pipe (Windows) is required for "
                 "--down and --status")

    if args.status:
        with Helper(endpoint) as helper:
            response = helper.call("status")
        print(json.dumps(response.get("status") or {}), flush=True)
        return 0

    if args.down:
        try:
            helper = Helper(endpoint)
        except HelperError as exc:
            # No helper to talk to is the state `down` is meant to reach, so a
            # teardown that finds nothing is a success, not a failure. This is
            # the path a test's addTearDown net takes after a run that died
            # before the tunnel ever came up.
            print(f"no helper to tear down ({exc}); treating as already down",
                  flush=True)
            return 0
        with helper:
            try:
                helper.call("down")
                print("tunnel down", flush=True)
            except HelperError as exc:
                # A `down` with nothing up is not a failure for a harness that is
                # tearing down on its way out.
                print(f"down reported {exc}; treating as already down", flush=True)
        return 0

    ap.error("nothing to do: pass --clear-devices, --down, or --status")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except StagingError as exc:
        raise SystemExit(f"e2e: {exc}") from None
