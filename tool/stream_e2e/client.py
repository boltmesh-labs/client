#!/usr/bin/env python3
"""Drives the client's privileged helper over its unix socket.

This is the harness's stand-in for the Flutter app: it speaks the same
newline-delimited JSON request/response protocol that `lib/features/vpn/data/
helper_client.dart` speaks, so what is exercised is the real daemon's real
`up`-with-a-transport path rather than a test double.

The transport spec it sends is built from the pin the *node* reported on its
heartbeat, read from the stub control plane. That ordering matters: the pin is
learned from a node that actually bound its ingress port, so a client that
succeeds here is pinning a live listener rather than a fixture constant.
"""

from __future__ import annotations

import argparse
import base64
import json
import secrets
import socket
import sys
from typing import Any

PROTOCOL_VERSION = 1
CAPS = ["strict-validation", "caps", "stream-transport"]
PSK_BYTES = 32
CLIENT_ID_BYTES = 16


class HelperError(RuntimeError):
    """The helper refused an operation.

    Carries the daemon's own code so a failure names *why* the daemon refused
    rather than surfacing as a generic transport error.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


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


def build_wg_quick_config(
    *,
    private_key: str,
    assigned_ip: str,
    server_public_key: str,
    listen_addr: str,
    dns: str,
) -> str:
    """The client's wg-quick config for the stream rung.

    Two fields are specific to this rung and both are the harness's job to get
    right, because they are what make the bridge work rather than something the
    daemon can infer:

    - the peer's `Endpoint` is the bridge's **loopback** address, not the node —
      the bridge is what reaches the node;
    - `ListenPort` is pinned to the bridge's **deliver** port. A bare `wg-quick`
      config would take an ephemeral port, and the bridge would have no way to
      know where to hand the node's datagrams.

    The obfuscation directives are deliberately absent: one rung at a time, and
    the daemon rejects the combination outright.
    """
    return (
        "[Interface]\n"
        f"PrivateKey = {private_key}\n"
        f"Address = {assigned_ip}\n"
        f"DNS = {dns}\n"
        f"ListenPort = {listen_addr.rsplit(':', 1)[1]}\n"
        "\n"
        "[Peer]\n"
        f"PublicKey = {server_public_key}\n"
        f"Endpoint = {listen_addr}\n"
        "AllowedIPs = 10.254.0.0/16\n"
        "PersistentKeepalive = 25\n"
    )


def wait_for_pin(control_plane: str, timeout: float = 30.0) -> str:
    """Blocks until the node has reported an SPKI pin on its heartbeat.

    The pin is the proof the ingress came up, so there is nothing to assert
    against until it exists.
    """
    import time
    import urllib.error
    import urllib.request

    deadline = time.monotonic() + timeout
    last = "no response from the stub control plane"
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(f"{control_plane}/harness/state", timeout=2) as resp:
                state = json.load(resp)
            pin = state.get("stream_spki_sha256")
            if pin:
                return pin
            last = "the node has not reported a pin yet"
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            last = f"stub control plane unreachable: {exc}"
        time.sleep(0.25)
    raise SystemExit(f"timed out waiting for the node's SPKI pin: {last}")


def free_udp_port() -> int:
    """Asks the kernel for a free loopback UDP port.

    Same probe the Flutter client performs (`allocateLoopbackPorts`): bind
    port 0, read the port, close. There is a narrow race between closing and the
    daemon binding, which is why the two ports are probed independently — and why
    a conflict surfaces as a `bad_config` from the helper rather than silently.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]
    finally:
        sock.close()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--socket", required=True, help="boltmeshd's unix socket path")
    ap.add_argument("--control-plane",
                    help="base URL of the stub control plane, for the node's reported pin. "
                         "Required unless --down, which needs nothing but the socket — so "
                         "teardown cannot fail merely because the stub has already gone away")
    ap.add_argument("--server", help="host:port the bridge dials, i.e. the node's ingress")
    ap.add_argument("--server-name", help="SNI, and the name the node issued for")
    ap.add_argument("--node-tunnel-ip", default="10.254.0.1")
    ap.add_argument("--client-ip", default="10.254.0.2/32")
    ap.add_argument("--state-out",
                    help="where to write the chosen keys, for the assertions")
    ap.add_argument("--down", action="store_true", help="tear the tunnel down and exit")
    args = ap.parse_args()

    # Validate the up-path arguments here rather than letting them be silently
    # empty: a missing --server would otherwise produce a conf pointing at
    # "None:0", and the run would fail somewhere much less legible.
    if not args.down:
        missing = [flag for flag, value in (
            ("--control-plane", args.control_plane),
            ("--server", args.server),
            ("--server-name", args.server_name),
            ("--state-out", args.state_out),
        ) if not value]
        if missing:
            ap.error("the following arguments are required without --down: "
                     + ", ".join(missing))

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

    # The node's WireGuard public half, which it reported at registration. The
    # client needs it as the peer key; there is no other channel carrying it.
    state = fetch_state(args.control_plane)
    node_public_key = state.get("node_public_key")
    if not node_public_key:
        raise SystemExit("the node has not registered yet (no wg_public_key)")

    pin = wait_for_pin(args.control_plane)

    listen_port = free_udp_port()
    deliver_port = free_udp_port()
    while deliver_port == listen_port:
        deliver_port = free_udp_port()

    # Fresh keypairs per run: a reused private key would be remembered by the
    # node's peer table from a previous run and hide a real failure.
    client_private = base64.b64encode(secrets.token_bytes(32)).decode("ascii")

    with Helper(args.socket) as helper:
        caps = helper.capabilities()
        if "stream-transport" not in caps:
            print(f"helper does not advertise stream-transport (caps={caps})", file=sys.stderr)
            return 1

        transport = {
            "mode": "stream",
            "listen": f"127.0.0.1:{listen_port}",
            "deliver": f"127.0.0.1:{deliver_port}",
            "server": args.server,
            "server_name": args.server_name,
            "spki_sha256": [pin],
            # The device credential, from the same control plane the node reads
            # it from, so the two ends cannot disagree about the PSK.
            "psk": state["psk"],
            "client_id": state["client_id"],
        }
        conf = build_wg_quick_config(
            private_key=client_private,
            assigned_ip=args.client_ip,
            server_public_key=node_public_key,
            listen_addr=transport["listen"],
            dns=args.node_tunnel_ip,
        )

        print(f"pin from the node's heartbeat: {pin}", flush=True)
        print(f"bridge listen={transport['listen']} deliver={transport['deliver']}", flush=True)
        response = helper.call("up", config=conf, transport=transport)
        status = response.get("status") or {}
        print(f"up: interface={status.get('interface')} stage={status.get('stage')} "
              f"endpoint={status.get('endpoint')}", flush=True)

    with open(args.state_out, "w", encoding="utf-8") as handle:
        json.dump({"client_private": client_private, "listen_port": listen_port,
                   "deliver_port": deliver_port, "pin": pin}, handle)
    print(f"wrote {args.state_out}", flush=True)
    return 0


def fetch_state(control_plane: str) -> dict[str, Any]:
    """Reads the stub control plane's harness state.

    Includes the device PSK, which the harness's own state endpoint serves over
    loopback. That is a deliberate lab-fixture choice, not a precedent for
    production: the real control plane hands the PSK only to the device's owner
    in an authenticated response, and never exposes it on a shared surface.
    """
    import urllib.request

    with urllib.request.urlopen(f"{control_plane}/harness/state", timeout=5) as resp:
        return json.load(resp)


if __name__ == "__main__":
    raise SystemExit(main())
