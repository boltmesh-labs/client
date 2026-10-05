#!/usr/bin/env python3
"""Socket-level utilities for the app e2e harness.

The end-to-end run itself is the Linux desktop app under
`integration_test/linux_app_e2e.dart`, driven by `run_linux_app.sh`. This script
is the utility that run wraps: it clears the account's devices before the app
starts, so a run that failed part-way cannot leave a device row that makes the
next run report a device limit, and it tears a live tunnel down from a test's
`addTearDown` net, which runs after the widget tree and its provider container
are gone.

It speaks the same newline-delimited JSON request/response protocol that
`lib/features/vpn/data/helper_client.dart` speaks, so what is exercised is the
real daemon over its real socket rather than a test double.

`--down` and `--status` need nothing but the socket, so teardown and status
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
    """One connection to boltmeshd, one request per call."""

    def __init__(self, path: str) -> None:
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.connect(path)
        self._buf = b""
        self._seq = 0

    def close(self) -> None:
        try:
            self._sock.close()
        except OSError:
            pass

    def __enter__(self) -> "Helper":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def _readline(self) -> bytes:
        while b"\n" not in self._buf:
            chunk = self._sock.recv(65536)
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
        self._sock.sendall(json.dumps(request).encode("utf-8") + b"\n")

        response = json.loads(self._readline())
        if not response.get("ok"):
            err = response.get("error") or {}
            raise HelperError(err.get("code", "unknown"), err.get("message", "no message"))
        return response

    def capabilities(self) -> list[str]:
        return self.call("ping").get("caps", [])


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
    ap.add_argument("--socket", help="boltmeshd's unix socket path")
    ap.add_argument("--api-user", help="API user")
    ap.add_argument("--api-password", help="API password")
    ap.add_argument("--api-base", help="API base URL, for the modes that read no socket")

    ap.add_argument("--down", action="store_true",
                    help="tear the tunnel down and exit. Needs only --socket")
    ap.add_argument("--status", action="store_true",
                    help="print the daemon's own view of the tunnel and exit. The "
                         "kernel's `wg show` cannot read a userspace AmneziaWG device, "
                         "so this is the equivalent read when the region is obfuscated. "
                         "Needs only --socket")
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

    if not args.socket:
        ap.error("--socket is required for --down and --status")

    if args.status:
        with Helper(args.socket) as helper:
            response = helper.call("status")
        print(json.dumps(response.get("status") or {}), flush=True)
        return 0

    if args.down:
        with Helper(args.socket) as helper:
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
