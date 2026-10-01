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


def obfuscation_lines(obfuscation: dict | None) -> str:
    """The AmneziaWG directives for a region's obfuscation descriptor.

    The inner WireGuard format follows the region, not the rung: a region whose
    node runs the obfuscated data plane hands its descriptor to every client, and
    the node's AmneziaWG device drops stock datagrams — so the stream rung's conf
    has to reproduce those directives. A `None` descriptor (a stock region) adds
    nothing. Mirrors the Flutter client's `buildWgQuickConfig` formatting,
    including the `lo-hi` range form for the magic headers.
    """
    if not obfuscation or obfuscation.get("mode") != "awg":
        return ""
    params = obfuscation.get("params") or {}
    lines = [
        f"Jc = {params['jc']}",
        f"Jmin = {params['jmin']}",
        f"Jmax = {params['jmax']}",
        f"S1 = {params['s1']}",
        f"S2 = {params['s2']}",
        f"S3 = {params['s3']}",
        f"S4 = {params['s4']}",
    ]
    for name in ("h1", "h2", "h3", "h4"):
        lo, hi = params[name]
        lines.append(f"{name.upper()} = {lo}-{hi}")
    return "\n".join(lines) + "\n"


def build_wg_quick_config(
    *,
    private_key: str,
    assigned_ip: str,
    server_public_key: str,
    endpoint: str,
    listen_port: int,
    allowed_ips: str,
    obfuscation: dict | None = None,
) -> str:
    """The client's wg-quick config for the stream rung.

    Three fields are specific to this rung and all three are the harness's job to
    get right, because they are what make the bridge work rather than something
    the daemon can infer:

    - the peer's `Endpoint` is the bridge's **listen** address, not the node —
      the bridge is what reaches the node;
    - the interface's `ListenPort` is the bridge's **deliver** port, the one the
      bridge sends the node's datagrams back to. It must NOT be the listen port:
      the bridge already holds that one, so the kernel would fail to bind it and
      `wg-quick up` would die with "Address already in use" on the *mtu* step,
      which points nowhere near the real cause.
    - `obfuscation` reproduces the region's descriptor when its node runs the
      AmneziaWG device. It is the *inner* format and is orthogonal to the rung:
      the bridge carries whatever the node's device expects.

    No `DNS=` line. It is in the Flutter client's config but cannot work here:
    `resolvconf` talks to a resolver running in the *host* namespace, which does
    not know this namespace's interface, so `wg-quick` would fail its DNS step
    and tear the link down. DNS is out of scope for a transport harness.
    """
    return (
        "[Interface]\n"
        f"PrivateKey = {private_key}\n"
        f"Address = {assigned_ip}\n"
        f"ListenPort = {listen_port}\n"
        f"{obfuscation_lines(obfuscation)}"
        "\n"
        "[Peer]\n"
        f"PublicKey = {server_public_key}\n"
        f"Endpoint = {endpoint}\n"
        f"AllowedIPs = {allowed_ips}\n"
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


class StagingError(RuntimeError):
    """The real control plane would not give us a usable transport."""


def _api_call(base: str, path: str, *, token: str | None = None, method: str = "GET",
              body: dict | None = None, form: dict | None = None) -> object:
    import urllib.error
    import urllib.parse
    import urllib.request

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
    # 429 is retried here rather than at each call site: the real API rate-limits
    # even `/auth/login`, so a harness that cannot back off cannot run at all
    # against it. Everything else is a real answer and propagates.
    import time

    for attempt in range(6):
        req = urllib.request.Request(f"{base.rstrip('/')}{path}", data=data,
                                     headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")
            if exc.code == 429 and attempt < 5:
                delay = 5 * (attempt + 1)
                print(f"  rate limited on {path}; retrying in {delay}s", flush=True)
                time.sleep(delay)
                continue
            raise StagingError(f"HTTP {exc.code} on {path}: {body[:300]}") from None
        except urllib.error.URLError as exc:
            raise StagingError(f"{path}: {exc.reason}") from None
    raise AssertionError("unreachable")


def transport_from_staging(state: dict, user: str, password: str,
                           timeout: float = 90.0) -> dict:
    """Creates (or reuses) the device and waits for the backend to hand back a transport.

    Against the stub this is unnecessary, because the fixture builds the descriptor
    by hand. Here the real schemas do, which is the whole point: a `stream` object
    that the backend produced is one the helpers must accept.

    Two ordering facts drive the shape of this function:

    * The device cannot be bound until the node has registered. A server has no
      WireGuard public key until a node registers it, and binding refuses a
      server that is not dialable — so this runs *after* the node is up.
    * The backend only emits `stream` once the node has reported a TLS pin, which
      it does after its ingress binds. So the config is polled rather than read
      once: before the pin exists there is simply no transport to return.
    """
    import time

    base = state["api_base"]
    login = _api_call(base, "/auth/login", method="POST", form={
        "grant_type": "password", "username": user, "password": password,
        "remember_me": "true",
    })
    token = login.get("access_token") if isinstance(login, dict) else None
    if not token:
        raise StagingError("login returned no access_token")

    # Defaulted, not required from the state file: a run that resumes from a state
    # written before the device step would otherwise look for a device named
    # `None`, find none, and create a duplicate — which is both wrong and, on the
    # strict rate limiter, slow to discover.
    device_name = state.get("device_name") or "harness-device"
    devices = _api_call(base, "/vpn-devices", token=token) or []
    device = next((d for d in devices if d.get("name") == device_name), None)
    if device is None:
        # A server is only selectable once a node has registered it *and* it has
        # heartbeated: registration fills its WireGuard key, the heartbeat clears
        # the staleness sweep. Both happen moments after the agent starts, so a
        # 503 here is "not yet", not "no" — retrying is what keeps the harness
        # from racing its own node.
        deadline = time.monotonic() + timeout
        while True:
            try:
                device = _api_call(base, "/vpn-devices", token=token, method="POST", body={
                    "name": device_name,
                    "platform": "linux",
                    "public_key": state["client_public_key"],
                    "region_id": state["region_id"],
                })
                break
            except StagingError as exc:
                retryable = "NO_SERVERS_AVAILABLE" in str(exc) or "RATE_LIMIT" in str(exc)
                if not retryable or time.monotonic() >= deadline:
                    raise
                print(f"device not creatable yet ({'rate limited' if 'RATE_LIMIT' in str(exc) else 'no dialable server'}); retrying",
                      flush=True)
                time.sleep(10)
        print(f"created device {device['id']}", flush=True)
    else:
        print(f"reusing device {device['id']}", flush=True)

    device_id = device["id"]
    deadline = time.monotonic() + timeout
    last = "the backend has not offered a stream transport yet"
    while time.monotonic() < deadline:
        try:
            payload = _api_call(base, f"/vpn-devices/{device_id}/config", token=token)
        except StagingError as exc:
            last = str(exc)
            time.sleep(2)
            continue
        if isinstance(payload, dict) and payload.get("stream"):
            print(f"the backend offered a stream transport for device {device_id}", flush=True)
            return payload
        last = "config carries no `stream` object (node has not reported a pin yet)"
        time.sleep(2)
    raise StagingError(f"no stream transport after {timeout:.0f}s: {last}")


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
    ap.add_argument("--client-ip", default="10.254.0.2/32",
                    help="the device's assigned overlay address. In staging mode the "
                         "backend is authoritative, so this is overridden from the "
                         "dial payload")
    ap.add_argument("--state-out",
                    help="where to write the chosen keys, for the assertions")
    ap.add_argument("--inline-client-private",
                    help="the client's WireGuard private key, wg genkey form. Supplied "
                         "when the harness has already registered the matching public "
                         "half with the control plane, so the node's peer and this conf "
                         "agree without a mid-run race")
    ap.add_argument("--force-psk",
                    help="override the PSK, for the negative check. The daemon must "
                         "refuse a session presenting a credential it was never told")
    ap.add_argument("--tunnel-cidr",
                    help="the node's tunnel subnet, for the conf's AllowedIPs. The dial "
                         "payload carries only the node's tunnel address, not the prefix "
                         "length it sits in, and a /32 there would leave the tunnel "
                         "unroutable")
    ap.add_argument("--staging-state",
                    help="state file from staging_setup.py. Selects the real backend: the "
                         "device is created and its transport read from the live API "
                         "instead of from the stub fixture")
    ap.add_argument("--api-user", help="API user, for --staging-state")
    ap.add_argument("--api-password", help="API password, for --staging-state")
    ap.add_argument("--down", action="store_true", help="tear the tunnel down and exit")
    ap.add_argument("--status", action="store_true",
                    help="print the daemon's own view of the tunnel and exit. The "
                         "kernel's `wg show` cannot read a userspace AmneziaWG device, "
                         "so this is the equivalent read when the region is obfuscated")
    args = ap.parse_args()

    # Validate the up-path arguments here rather than letting them be silently
    # empty: a missing --server would otherwise produce a conf pointing at
    # "None:0", and the run would fail somewhere much less legible.
    if not (args.down or args.status):
        # In staging mode the backend supplies the server, its name and the
        # device's address, so only the socket and the output path are the
        # caller's to provide.
        required_args = [("--state-out", args.state_out)]
        if not args.staging_state:
            required_args += [
                ("--control-plane", args.control_plane),
                ("--server", args.server),
                ("--server-name", args.server_name),
            ]
        missing = [flag for flag, value in required_args if not value]
        if missing:
            ap.error("the following arguments are required without --down: "
                     + ", ".join(missing))

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

    # The node's WireGuard public half, which it reported at registration. The
    # client needs it as the peer key; there is no other channel carrying it.
    if args.staging_state:
        if not (args.api_user and args.api_password):
            raise SystemExit("--staging-state also needs --api-user and --api-password")
        state = json.load(open(args.staging_state))
        payload = transport_from_staging(state, args.api_user, args.api_password)
        stream = payload["stream"]
        node_public_key = payload.get("wg_public_key")
        if not node_public_key:
            raise SystemExit("the dial payload carries no wg_public_key")
        pin = stream["spki_sha256"][0]
        client_private = state["client_private_key"]
        node_tunnel_ip = payload.get("wg_dns") or ""
        # The region's inner format, from the same dial payload the Flutter
        # client reads. A stock region carries null here.
        obfuscation = payload.get("obfuscation")
        # The backend is authoritative about where its node is and what it is
        # called; the harness's own flags would be a second source of truth.
        args.server = stream["server"]
        args.server_name = stream["server_name"]
        if payload.get("assigned_ip"):
            args.client_ip = payload["assigned_ip"]
        if not args.tunnel_cidr:
            raise SystemExit("--staging-state also needs --tunnel-cidr "
                             "(the node's tunnel subnet, for AllowedIPs)")
    else:
        state = fetch_state(args.control_plane)
        node_public_key = state.get("node_public_key")
        if not node_public_key:
            raise SystemExit("the node has not registered yet (no wg_public_key)")
        pin = wait_for_pin(args.control_plane)
        client_private = None
        stream = None
        obfuscation = None
        node_tunnel_ip = args.node_tunnel_ip

    listen_port = free_udp_port()
    deliver_port = free_udp_port()
    while deliver_port == listen_port:
        deliver_port = free_udp_port()

    # Fresh keypairs per run unless the harness supplied one: a reused private key
    # would be remembered by the node's peer table from a previous run and hide a
    # real failure. When it did supply one, that is the private half of the public
    # key it already registered with the control plane, and the node's peer row is
    # built from that public key — so the two must be used together.
    client_private = (client_private or args.inline_client_private
                      or base64.b64encode(secrets.token_bytes(32)).decode("ascii"))

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
            # it from, so the two ends cannot disagree about the PSK. Overridable
            # only so the negative check can present one the node never saw.
            "psk": args.force_psk or (stream["psk"] if stream else state["psk"]),
            "client_id": stream["client_id"] if stream else state["client_id"],
        }
        conf = build_wg_quick_config(
            private_key=client_private,
            assigned_ip=args.client_ip,
            server_public_key=node_public_key,
            # The peer endpoint is the bridge; the interface's own port is the
            # bridge's deliver port. Swapping these is the one mistake that makes
            # a correct transport look broken, so they are separate arguments.
            endpoint=transport["listen"],
            listen_port=deliver_port,
            allowed_ips=args.tunnel_cidr or "10.254.0.0/16",
            obfuscation=obfuscation,
        )

        print(f"pin from the node's heartbeat: {pin}", flush=True)
        print(f"bridge listen={transport['listen']} deliver={transport['deliver']}", flush=True)
        print(f"inner format={(obfuscation or {}).get('mode') or 'native'}", flush=True)
        response = helper.call("up", config=conf, transport=transport)
        status = response.get("status") or {}
        print(f"up: interface={status.get('interface')} stage={status.get('stage')} "
              f"endpoint={status.get('endpoint')}", flush=True)

    with open(args.state_out, "w", encoding="utf-8") as handle:
        json.dump({"client_private": client_private, "listen_port": listen_port,
                   "deliver_port": deliver_port, "pin": pin,
                   "node_tunnel_ip": node_tunnel_ip,
                   "assigned_ip": args.client_ip, "server": args.server,
                   "server_name": args.server_name,
                   # Which read the assertions should use: the kernel's `wg show`
                   # cannot see a userspace AmneziaWG device.
                   "inner_format": (obfuscation or {}).get("mode") or "native"},
                  handle)
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
