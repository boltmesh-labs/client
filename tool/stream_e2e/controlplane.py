#!/usr/bin/env python3
"""Stub control plane for the stream-transport end-to-end harness.

It answers only what a node needs to come up and start serving, so the harness
can exercise the real transport between two real helper processes without
standing up Postgres and the real API. It is a lab fixture, not a control
plane: nothing here enforces an entitlement, an auth, or a quota.

Endpoints (all under the agent's /v1 prefix):

  POST /v1/control-plane/register/manual  → the registration response, carrying
                                            the `stream_ingress` descriptor
  POST /v1/control-plane/heartbeat        → accepted, and the node's reported
                                            `stream_spki_sha256` is recorded
  GET  /v1/control-plane/peers-sync       → one peer, with its stream credential
  GET  /v1/control-plane/peers-watch      → not dirty, so the agent re-polls on
                                            its normal 30s ticker instead of
                                            waiting on a long poll
  POST /v1/control-plane/auth/token       → re-mints the node token
  POST /v1/control-plane/auth/refresh-token → refreshes it

The registration response's `server_name` is what the node mints its certificate
for, so this fixture chooses it to match the name the client will present as SNI
— the same string the real control plane derives from the server's endpoint. The
harness reads that same value back from `/harness/state` so the client's pin and
SNI cannot drift from what the node actually issued for.

The heartbeat is where the node reports its SPKI pin, so the fixture captures it
there. That ordering is the point: the client's pin is only ever the pin of an
ingress that actually bound its port.
"""

from __future__ import annotations

import argparse
import json
import secrets
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

# Sizes the agent and client both validate. Generated here rather than hardcoded
# so the fixture cannot accidentally drift from the contract without the tests
# noticing.
PSK_BYTES = 32
CLIENT_ID_BYTES = 16

_lock = threading.Lock()


class State:
    """Everything the fixture serves, mutable so tests can steer it.

    Kept in one object rather than module globals so a test can construct an
    isolated instance instead of relying on test ordering.
    """

    def __init__(self, server_name: str, listen_port: int, wg_port: int) -> None:
        self.server_name = server_name
        self.listen_port = listen_port
        self.wg_port = wg_port
        self.tunnel_ip = "10.254.0.1/16"
        self.interface = "wg0"
        self.node_id = "11111111-2222-3333-4444-555555555555"
        self.node_token = "vpn_node_harness_token"
        # The node's reported identity. Empty until the first heartbeat that
        # carries one; the harness waits for this before asserting anything.
        self.stream_spki_sha256: str | None = None
        # The device's credential. Generated once so the client and the node are
        # guaranteed to be handed the same values from the same control plane.
        self.client_id = _b64(secrets.token_bytes(CLIENT_ID_BYTES))
        self.psk = _b64(secrets.token_bytes(PSK_BYTES))
        # The client device's WireGuard public key, learned at registration the
        # way the real control plane learns it: the client generates its keypair
        # and sends only the public half, and the node needs that half to build
        # the peer. Passed in by the harness because the client half runs in
        # another process.
        self.node_public_key: str | None = None
        self.client_public_key: str | None = None
        self.heartbeat_count = 0
        self.peers_sync_count = 0

    def registration(self) -> dict[str, Any]:
        return {
            "node_token": self.node_token,
            "token_expires_in": 900,
            "interface_name": self.interface,
            "tunnel_ip": self.tunnel_ip,
            "node_id": self.node_id,
            "name": "harness-node",
            "region": "harness",
            "region_name": "Harness",
            "region_country": "US",
            "os": "rocky",
            "public_ip": "198.51.100.2",
            "endpoint": self.server_name,
            "wg_port": self.wg_port,
            # No `obfuscation`: the harness exercises the stream rung directly,
            # and one rung at a time is the contract.
            "stream_ingress": {
                "enabled": True,
                "listen_port": self.listen_port,
                "server_name": self.server_name,
            },
        }

    def peer(self) -> dict[str, Any]:
        # `public_key` is the client's WireGuard public half. A node cannot build
        # the peer without it, so an unset value would make the harness fail for
        # a reason that looks like a sync bug. The harness registers the client's
        # key up front rather than mid-run, so peers-sync is stable from the
        # node's very first fetch.
        return {
            "id": "99999999-8888-7777-6666-555555555555",
            "public_key": self.client_public_key or "",
            "assigned_ip": "10.254.0.2/32",
            "speed_limit_mbps": 0,
            "stream": {"client_id": self.client_id, "psk": self.psk},
        }

    def snapshot(self) -> dict[str, Any]:
        with _lock:
            return {
                "server_name": self.server_name,
                "listen_port": self.listen_port,
                "stream_spki_sha256": self.stream_spki_sha256,
                "client_id": self.client_id,
                # Included because the harness is a lab fixture serving over a
                # loopback socket, and the client half needs the PSK it hands to
                # the bridge. The real control plane never exposes a device PSK on
                # a shared read surface — it goes only to the device's owner in an
                # authenticated response. Do not copy this shape.
                "psk": self.psk,
                "node_public_key": self.node_public_key,
                # The host address of the node's tunnel subnet, which the client
                # half pings across the finished tunnel. The real control plane
                # carries this as `wg_dns` in the dial payload (always the tunnel
                # host address); here the stub is the dial payload, so it serves
                # the same value the same way. Derived from the same tunnel_ip the
                # node is registered with, so the two cannot disagree.
                "node_tunnel_ip": self.tunnel_ip.split("/")[0],
                "heartbeat_count": self.heartbeat_count,
                "peers_sync_count": self.peers_sync_count,
            }


def _b64(raw: bytes) -> str:
    import base64

    return base64.b64encode(raw).decode("ascii")


class Handler(BaseHTTPRequestHandler):
    state: State

    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        # Only unexpected traffic is interesting; the harness prints its own
        # progress, and per-request lines would bury it.
        pass

    def _send(self, code: int, body: Any) -> None:
        raw = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        if length == 0:
            return {}
        try:
            return json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            return {}

    # --- routes -----------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802 (http.server's naming)
        path = self.path.split("?", 1)[0]
        if path.endswith("/peers-sync"):
            with _lock:
                self.state.peers_sync_count += 1
            self._send(200, [self.state.peer()])
            return
        if path.endswith("/peers-watch"):
            # Never dirty: the agent falls back to its 30s peers-sync ticker,
            # which is enough for a harness that drives convergence explicitly.
            self._send(200, {"generation": 0, "dirty": False})
            return
        if path.endswith("/harness/state"):
            self._send(200, self.state.snapshot())
            return
        self._send(404, {"detail": f"no stub route for GET {path}"})

    def do_POST(self) -> None:  # noqa: N802 (http.server's naming)
        path = self.path.split("?", 1)[0]
        body = self._read_json()
        if path.endswith("/register/manual") or path.endswith("/register/ami"):
            # The node reports its own WireGuard public half at registration; the
            # client needs it as the peer key in its wg-quick config, and there is
            # no other channel carrying it.
            public_key = body.get("wg_public_key")
            if isinstance(public_key, str) and public_key:
                with _lock:
                    self.state.node_public_key = public_key
            self._send(201, self.state.registration())
            return
        if path.endswith("/heartbeat"):
            self._on_heartbeat(body)
            return
        if path.endswith("/auth/token") or path.endswith("/auth/refresh-token"):
            # `expires_at` is a string, not a number: the agent decodes it into a
            # Go `string` and a bare 0 fails the whole refresh, which is how this
            # surfaced as "node has not reported a pin yet" — the startup task
            # chain aborts before the first heartbeat. The agent treats empty as
            # "no absolute expiry", so an empty string is both valid and honest.
            self._send(200, {
                "node_token": self.state.node_token,
                "token_expires_in": 900,
                "expires_at": "",
            })
            return
        self._send(404, {"detail": f"no stub route for POST {path}"})

    def _on_heartbeat(self, body: dict[str, Any]) -> None:
        # The node reports its SPKI pin here. Record it so the harness (and the
        # client) can learn the pin only from a node that actually came up.
        pin = body.get("stream_spki_sha256")
        with _lock:
            self.state.heartbeat_count += 1
            if isinstance(pin, str) and pin:
                self.state.stream_spki_sha256 = pin
        self._send(200, {"status": "online"})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--server-name", required=True,
                    help="name the node mints its certificate for and the client presents as SNI")
    ap.add_argument("--stream-port", type=int, required=True,
                    help="the ingress's public port in this harness")
    ap.add_argument("--wg-port", type=int, default=51820,
                    help="the node's WireGuard port (must differ from --stream-port)")
    ap.add_argument("--client-public-key", required=True,
                    help="the client device's WireGuard public half, for the node's peer")
    args = ap.parse_args()

    if args.stream_port == args.wg_port:
        print("stream port and wg port must differ", file=sys.stderr)
        return 2

    Handler.state = State(args.server_name, args.stream_port, args.wg_port)
    # Registered up front so the node's first peers-sync already carries a usable
    # peer: the harness drives convergence explicitly and should not have to wait
    # out the 30s ticker before the bridge can authenticate anything.
    Handler.state.client_public_key = args.client_public_key
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"stub control plane on {args.host}:{args.port} "
          f"(server_name={args.server_name}, stream_port={args.stream_port})",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
