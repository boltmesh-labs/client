#!/usr/bin/env python3
"""Drives the client's privileged helper over its unix socket.

This is the e2e harness's stand-in for the Flutter app: it speaks the same
newline-delimited JSON request/response protocol that `lib/features/vpn/data/
helper_client.dart` speaks, so what is exercised is the real daemon's real
`up`-with-a-transport path rather than a test double.

Everything it needs comes from the deployed control plane: the device is created
through the real API, and the transport spec is built from the descriptor that
API served — including the SPKI pin, which the backend only emits once the *real*
node has reported that its ingress bound and reported a pin on its heartbeat. So
the pin being present is itself evidence that a node is up and serving.

`--down` and `--status` need nothing but the socket, so teardown and status
reads cannot fail merely because the API or the node has gone away.
"""

from __future__ import annotations

import argparse
import base64
import json
import socket
import sys
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
    """The real control plane would not give us a usable transport."""


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


def ensure_device(base: str, token: str, state: dict, timeout: float = 120.0) -> str:
    """Creates (or reuses) this run's device and returns its id.

    Reuse by name is only safe when the backend already knows *this* public key.
    A state file that was lost regenerates the keypair, and the backend keeps the
    old public half — so the client would hold a private key the node has no
    matching public key for, and the tunnel would never handshake. That failure
    looks like a network problem, not a fixture mismatch, so it is refused here.

    A 503 while creating is "not yet", not "no": a server only becomes selectable
    once a node has registered it *and* heartbeated (registration fills its
    WireGuard key, the heartbeat clears the staleness sweep). Retrying is what
    keeps a fresh run from losing that race.
    """
    device_name = state.get("device_name") or "e2e-device"
    devices = _api_call(base, "/vpn-devices", token=token) or []
    rows = devices.get("data", devices) if isinstance(devices, dict) else devices
    device = next((d for d in rows if d.get("name") == device_name), None)

    if device is not None:
        # The identity to compare against is the *peer's* public key, read from the
        # device's dial payload. `GET /vpn-devices` is a summary and carries no key
        # at all, so reading `public_key` off it compares against None and refuses
        # every reuse — which would make the negative checks pass for the wrong
        # reason, having never reached the credential they meant to test.
        config = _api_call(base, f"/vpn-devices/{device['id']}/config", token=token)
        registered = (config.get("client_public_key")
                      if isinstance(config, dict) else None)
        if registered != state["client_public_key"]:
            raise StagingError(
                f"device {device_name!r} is bound with a different WireGuard public "
                f"key than the one in the state file.\n"
                f"  registered: {registered}\n"
                f"  this run:   {state['client_public_key']}\n"
                f"Delete the stored keypair to start a new device, or point --state at "
                f"the file written when this device was created. The backend never "
                f"stores the private half, so a lost keypair cannot be recovered."
            )
        print(f"reusing device {device['id']}", flush=True)
        return device["id"]

    deadline = time.monotonic() + timeout
    while True:
        try:
            created = _api_call(base, "/vpn-devices", token=token, method="POST", body={
                "name": device_name,
                "platform": "linux",
                "public_key": state["client_public_key"],
                "region_id": state["region_id"],
            })
            assert isinstance(created, dict)
            print(f"created device {created['id']}", flush=True)
            return created["id"]
        except StagingError as exc:
            # Matched as the backend actually spells it. NO_VPN_SERVERS_AVAILABLE
            # does not contain the shorter NO_SERVERS_AVAILABLE, and a retry that
            # does not fire turns this race into the harness's own startup failure.
            retryable = ("NO_VPN_SERVERS_AVAILABLE" in str(exc)
                         or "RATE_LIMIT_EXCEEDED" in str(exc))
            if not retryable or time.monotonic() >= deadline:
                raise
            print(f"device not creatable yet ({'rate limited' if 'RATE_LIMIT_EXCEEDED' in str(exc) else 'no dialable server'}); retrying",
                  flush=True)
            time.sleep(10)


def fetch_dial_payload(base: str, token: str, device_id: str, timeout: float = 120.0) -> dict:
    """Polls the device's config until the backend advertises the stream rung.

    A rung is only advertised once it can actually be started. The stream entry in
    particular needs the node's SPKI pin, which the node reports on its heartbeat
    after its ingress binds — so before that there is no stream entry at all, and
    the config is polled rather than read once.
    """
    deadline = time.monotonic() + timeout
    last = "no stream rung advertised yet"
    while time.monotonic() < deadline:
        try:
            payload = _api_call(base, f"/vpn-devices/{device_id}/config", token=token)
        except StagingError as exc:
            last = str(exc)
            time.sleep(2)
            continue
        if isinstance(payload, dict) and find_transport(payload, "stream"):
            print(f"the backend advertised the stream rung for device {device_id}", flush=True)
            return payload
        if isinstance(payload, dict):
            offered = [t.get("rung") for t in payload.get("transports") or []]
            last = (f"advertised rungs: {offered or ['none']} — the node serves no stream "
                    f"rung, which means its ingress has not reported a pin")
        time.sleep(2)
    raise StagingError(f"no stream rung after {timeout:.0f}s: {last}")


def find_transport(payload: dict, rung: str) -> dict | None:
    """The advertised entry for `rung`, or None.

    Read off the ordered list rather than by looking for a rung-specific key at
    the top level: the list states which rungs this node serves this device on and
    in what order, and absence from it is the single meaning of "not served".
    """
    for entry in payload.get("transports") or []:
        if entry.get("rung") == rung:
            return entry
    return None


# --- the client's WireGuard config -----------------------------------------


def obfuscation_lines(obfuscation: dict | None) -> str:
    """The AmneziaWG directives for a region's obfuscation descriptor.

    The inner WireGuard format follows the region, not the rung: a region whose
    node runs the obfuscated data plane hands its descriptor to every client, and
    the node's AmneziaWG device drops stock datagrams — so the conf has to
    reproduce those directives. A `None` descriptor (a stock region) adds nothing.
    Mirrors the Flutter client's `buildWgQuickConfig` formatting, including the
    `lo-hi` range form for the magic headers.
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


def host_route(address: str) -> str:
    """`10.3.0.1` or `10.3.0.1/24` → `10.3.0.1/32`.

    The dial payload carries the node's tunnel address but not the prefix length it
    sits in, so a subnet cannot be reconstructed from it — and a subnet supplied from
    outside is a second source of truth that silently disagrees with whichever node
    the API happened to assign. A host route needs no prefix and is correct whatever
    the node's subnet is. The harness only ever addresses the node itself, so this
    covers the whole test; it mirrors what the Flutter client does for its resolver.
    """
    bare = address.split("/")[0].strip()
    if not bare:
        raise SystemExit(f"no address to route: {address!r}")
    return f"{bare}/32"


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
    `resolvconf` talks to a resolver that does not know this tunnel's interface,
    so `wg-quick` would fail its DNS step and tear the link down. DNS is out of
    scope for a transport harness.
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
    ap.add_argument("--state",
                    help="state file holding this run's device keypair and region, "
                         "written by run.sh. The device itself is created through the "
                         "API, so nothing here needs to pre-exist on the backend")
    ap.add_argument("--api-user", help="API user")
    ap.add_argument("--api-password", help="API password")
    ap.add_argument("--api-base", help="API base URL, for the modes that read no state file")

    ap.add_argument("--state-out",
                    help="where to write the chosen keys and ports, for the assertions")
    ap.add_argument("--force-psk",
                    help="override the PSK, for the negative check. The daemon must "
                         "refuse a session presenting a credential it was never told")
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
        ap.error("--socket is required")

    if args.down or args.status:
        if args.status:
            with Helper(args.socket) as helper:
                response = helper.call("status")
            print(json.dumps(response.get("status") or {}), flush=True)
            return 0
        with Helper(args.socket) as helper:
            try:
                helper.call("down")
                print("tunnel down", flush=True)
            except HelperError as exc:
                # A `down` with nothing up is not a failure for a harness that is
                # tearing down on its way out.
                print(f"down reported {exc}; treating as already down", flush=True)
        return 0

    missing = [flag for flag, value in (
        ("--state", args.state),
        ("--api-user", args.api_user),
        ("--api-password", args.api_password),
        ("--state-out", args.state_out),
    ) if not value]
    if missing:
        ap.error("the following arguments are required to bring the tunnel up: "
                 + ", ".join(missing))

    state = json.load(open(args.state))
    base = state["api_base"]
    token = login(base, args.api_user, args.api_password)
    device_id = ensure_device(base, token, state)
    payload = fetch_dial_payload(base, token, device_id)

    # The backend is authoritative about where its node is, what it is called, and
    # what this device's address is; a second source of truth here would be a way
    # to test a node other than the one the API assigned.
    stream_entry = find_transport(payload, "stream")
    credential = stream_entry["credential"]
    server = credential["server"]
    server_name = credential["server_name"]
    pin = credential["spki_sha256"][0]
    assigned_ip = payload["assigned_ip"]
    node_public_key = payload.get("wg_public_key")
    if not node_public_key:
        raise SystemExit("the dial payload carries no wg_public_key")
    node_tunnel_ip = payload.get("wg_dns") or ""
    if not node_tunnel_ip:
        raise SystemExit("the dial payload carries no wg_dns (the node's tunnel address)")

    # The stream rung is *stock*, even on a node that also serves the obfuscated
    # one: the node's bridge injects into its stock device, so a stream session
    # carries stock WireGuard datagrams whatever else that node serves. So the
    # obfuscation parameters come off the stream entry — which carries none — and
    # never off the awg entry. Reading them across would put an AmneziaWG conf in
    # front of a stock device: it handshakes with nobody and the run fails for a
    # reason that has nothing to do with the transport under test.
    obfuscation = None

    # AllowedIPs is derived from the payload, never supplied: the API assigns the
    # node, and a subnet from outside is a value that can name a different node's
    # network than the one actually serving — which fails as "no route to host" and
    # reads like the tunnel is broken.
    allowed_ips = ",".join([host_route(assigned_ip), host_route(node_tunnel_ip)])

    listen_port = free_udp_port()
    deliver_port = free_udp_port()
    while deliver_port == listen_port:
        deliver_port = free_udp_port()

    client_private = state["client_private_key"]
    inner_format = (obfuscation or {}).get("mode") or "native"

    with Helper(args.socket) as helper:
        caps = helper.capabilities()
        if "stream-transport" not in caps:
            print(f"helper does not advertise stream-transport (caps={caps})", file=sys.stderr)
            return 1

        transport = {
            "mode": "stream",
            "listen": f"127.0.0.1:{listen_port}",
            "deliver": f"127.0.0.1:{deliver_port}",
            "server": server,
            "server_name": server_name,
            "spki_sha256": [pin],
            # The device credential, from the same API response the node read it
            # from, so the two ends cannot disagree about the PSK. Overridable only
            # so the negative check can present one the node never saw.
            "psk": args.force_psk or credential["psk"],
            "client_id": credential["client_id"],
        }
        conf = build_wg_quick_config(
            private_key=client_private,
            assigned_ip=assigned_ip,
            server_public_key=node_public_key,
            # The peer endpoint is the bridge; the interface's own port is the
            # bridge's deliver port. Swapping these is the one mistake that makes
            # a correct transport look broken, so they are separate arguments.
            endpoint=transport["listen"],
            listen_port=deliver_port,
            allowed_ips=allowed_ips,
            obfuscation=obfuscation,
        )

        print(f"node {server} ({server_name})", flush=True)
        print(f"pin from the node's heartbeat: {pin}", flush=True)
        print(f"bridge listen={transport['listen']} deliver={transport['deliver']}", flush=True)
        print(f"inner format={inner_format}", flush=True)
        response = helper.call("up", config=conf, transport=transport)
        status = response.get("status") or {}
        print(f"up: interface={status.get('interface')} stage={status.get('stage')} "
              f"endpoint={status.get('endpoint')}", flush=True)

    with open(args.state_out, "w", encoding="utf-8") as handle:
        json.dump({"client_private": client_private,
                   "listen_port": listen_port, "deliver_port": deliver_port,
                   "pin": pin, "node_tunnel_ip": node_tunnel_ip,
                   "assigned_ip": assigned_ip, "server": server,
                   "server_name": server_name, "allowed_ips": allowed_ips,
                   "device_id": device_id, "inner_format": inner_format},
                  handle)
    print(f"wrote {args.state_out}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except StagingError as exc:
        raise SystemExit(f"e2e: {exc}") from None
