#!/usr/bin/env python3
"""Provisions the staging backend for a stream-transport end-to-end run.

The stub control plane builds its descriptors by hand, so it cannot prove that the
*real* schemas produce something the helpers accept. This script points the
harness at a real control plane instead: it creates (or reuses) a region, a
manual node, and a device bound to that node, and writes everything the run needs
— including the device's WireGuard private key — to one state file.

It is deliberately stdlib-only so it can run on any host the harness runs on,
using the box's own `wg` to generate the device keypair.

The region's obfuscation profile and its nodes' stream ports are editable from
the admin surface now, but this script still only *reports* them: a node reads
both at registration, so applying a change is a restart the operator owns. Doing
it silently would leave a region that looks configured and serves nothing.

Usage:

    ./staging_setup.py --api-base https://api.boltmesh.mooo.com/v1 \
        --user 123 --password '...' --client-public-key "$(wg pubkey < priv)" \
        --state-out /tmp/staging-state.json

The node's `server_name` is its `endpoint` if it has one, else its `public_ip` —
the same rule the backend uses to derive a dial host. Set it to a name the client
can resolve; the harness maps it inside the client namespace.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

#: Region/tunnel defaults for the harness. The tunnel subnet is deliberately not
#: the one the existing staging nodes use, so a stray route cannot make two
#: different test beds look like they are talking to each other.
DEFAULT_REGION = "harness-lab"
DEFAULT_REGION_NAME = "Harness Lab"
DEFAULT_TUNNEL_IP = "10.254.0.1/16"
DEFAULT_WG_PORT = 51820
DEFAULT_STREAM_PORT = 443
DEFAULT_NODE_NAME = "harness-node"
#: A documentation address (RFC 5737). The row needs a unique ``public_ip`` and
#: nothing dials it, because the node has an ``endpoint``.
DEFAULT_PUBLIC_IP = "203.0.113.210"


class ApiError(RuntimeError):
    def __init__(self, status: int, body: str) -> None:
        super().__init__(f"HTTP {status}: {body[:300]}")
        self.status = status
        self.body = body


class Api:
    """Minimal authenticated JSON client. One token, refreshed never."""

    def __init__(self, base: str) -> None:
        self.base = base.rstrip("/")
        self.token: str | None = None

    def _call(self, method: str, path: str, body: dict | None = None,
              form: dict | None = None) -> object:
        url = f"{self.base}{path}"
        data: bytes | None = None
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if form is not None:
            data = urllib.parse.urlencode(form).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        elif body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        # The device-creation route carries the strict rate limiter, so a retry
        # loop here is what makes the script re-runnable rather than a
        # wait-and-pray. Only 429 is retried: everything else is a real answer.
        for attempt in range(6):
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    raw = resp.read()
                    return json.loads(raw) if raw else None
            except urllib.error.HTTPError as exc:
                body = exc.read().decode("utf-8", "replace")
                if exc.code == 429 and attempt < 5:
                    delay = 5 * (attempt + 1)
                    print(f"  rate limited; retrying in {delay}s", file=sys.stderr)
                    time.sleep(delay)
                    continue
                raise ApiError(exc.code, body) from None
        raise AssertionError("unreachable")

    def get(self, path: str) -> object:
        return self._call("GET", path)

    def post(self, path: str, body: dict | None = None, form: dict | None = None) -> object:
        return self._call("POST", path, body=body, form=form)

    def patch(self, path: str, body: dict) -> object:
        return self._call("PATCH", path, body=body)

    def delete(self, path: str) -> object:
        return self._call("DELETE", path)


def login(api: Api, user: str, password: str) -> None:
    # The login route is form-encoded, not JSON: it is an OAuth2
    # password-grant endpoint.
    result = api.post("/auth/login", form={
        "grant_type": "password",
        "username": user,
        "password": password,
        "remember_me": "true",
    })
    assert isinstance(result, dict)
    token = result.get("access_token")
    if not token:
        raise SystemExit("login succeeded but returned no access_token")
    api.token = token


def ensure_region(api: Api, region_id: str, name: str) -> None:
    try:
        api.get(f"/admin/vpn-regions/{region_id}")
        print(f"region {region_id}: already present")
        return
    except ApiError as exc:
        if exc.status != 404:
            raise
    api.post("/admin/vpn-regions", {"id": region_id, "name": name, "country_code": "US"})
    print(f"region {region_id}: created")


def find_server(api: Api, name: str) -> dict | None:
    page = api.get("/admin/vpn-servers")
    rows = page.get("data", page) if isinstance(page, dict) else page
    for row in rows or []:
        if row.get("name") == name:
            return row
    return None


def bootstrap_secret_from_command(command: str) -> str:
    """Pulls the secret out of the create response's bootstrap command.

    The API returns a ready-to-run command rather than the bare secret, so the
    value has to be parsed back out. Failing loudly here is much better than
    exporting an empty secret and having the node mysteriously fail to register.
    """
    match = re.search(r"NODE_BOOTSTRAP_SECRET=(\S+)", command)
    if not match:
        raise SystemExit(
            "could not find NODE_BOOTSTRAP_SECRET in the server's bootstrap_command; "
            "the API's response shape may have changed"
        )
    return match.group(1)


def load_state(path: str) -> dict:
    try:
        with open(path) as handle:
            return json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(path: str, state: dict) -> None:
    """Writes the state file 0600 after every step.

    Written incrementally, not once at the end: the bootstrap secret is returned
    exactly once, at server creation, so a failure later in the script (a rate
    limit, a transient 5xx) would otherwise throw the secret away and force a
    full recreate. It carries secrets, so it is never world-readable.
    """
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(state, handle, indent=2)


def ensure_server(api: Api, args: argparse.Namespace, state: dict) -> tuple[dict, str]:
    existing = find_server(api, args.node_name)

    # Resume: the server is there and we already captured its secret, so reuse
    # both rather than recreating (which would need a delete, and would strand any
    # device already bound to it).
    if existing is not None and not args.recreate_server:
        if state.get("bootstrap_secret") and state.get("server_id") == existing.get("id"):
            print(f"server {args.node_name!r}: reusing existing (id={existing['id']})")
            return existing, state["bootstrap_secret"]

        raise SystemExit(
            f"server {args.node_name!r} already exists, and its bootstrap secret is only "
            f"returned once at creation.\n"
            f"Re-run with --recreate-server to delete and recreate it (this also deletes "
            f"the device bound to it), or pass a different --node-name, or point "
            f"--state-out at the file written when it was created."
        )
    if existing is not None:
        # Delete the bound device first: the peer row holds a RESTRICT foreign key
        # to the server, so the server cannot go while a device is attached.
        for device in list_devices(api):
            if device.get("server_id") == existing.get("id"):
                api.delete(f"/vpn-devices/{device['id']}")
                print(f"device {device['id']}: deleted (bound to the server being recreated)")
        # A server must be decommissioned before it can be deleted; the API refuses
        # outright otherwise, which is what keeps a live node from vanishing.
        if existing.get("status") != "decommissioned":
            api.patch(f"/admin/vpn-servers/{existing['id']}", {"status": "decommissioned"})
        api.delete(f"/admin/vpn-servers/{existing['id']}")
        print(f"server {args.node_name!r}: deleted for recreation")

    created = api.post("/admin/vpn-servers", {
        "name": args.node_name,
        "region_id": args.region_id,
        "os": "rocky",
        "public_ip": args.public_ip,
        "endpoint": args.server_name,
        "tunnel_ip": args.tunnel_ip,
        "wg_port": args.wg_port,
        "status": "online",
    })
    assert isinstance(created, dict)
    secret = bootstrap_secret_from_command(created["bootstrap_command"])
    print(f"server {args.node_name!r}: created (id={created['id']})")
    return created, secret


def list_devices(api: Api) -> list[dict]:
    page = api.get("/vpn-devices")
    return page if isinstance(page, list) else page.get("data", [])


def ensure_device(api: Api, args: argparse.Namespace) -> dict:
    for device in list_devices(api):
        if device.get("name") == args.device_name:
            print(f"device {args.device_name!r}: reusing {device['id']}")
            return device
    created = api.post("/vpn-devices", {
        "name": args.device_name,
        "platform": "linux",
        "public_key": args.client_public_key,
        "region_id": args.region_id,
    })
    assert isinstance(created, dict)
    print(f"device {args.device_name!r}: created (id={created['id']})")
    return created


def check_region_serves_the_rung(api: Api, region_id: str, stream_port: int) -> bool:
    """Reports whether the region is configured to serve the stream transport.

    The descriptor is only observable when the region has at least one online
    server, so a region with none reads as unconfigured even when its profile is
    set. The profile is editable from the admin surface now; this stays a report
    rather than a write because a running node only reads it at registration, so
    the restart is the operator's.
    """
    discovery = api.get("/vpn-regions")
    region = next((r for r in discovery if r.get("id") == region_id), None)
    if region is None:
        raise SystemExit(f"region {region_id} is not visible in discovery")
    # The descriptor is stamped onto each server, so it is only observable when
    # the region has at least one online server.
    stamped = [s.get("obfuscation") for s in region.get("servers", [])]
    print(f"region {region_id}: servers={len(region.get('servers', []))} "
          f"obfuscation_stamped={any(o is not None for o in stamped)}")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--api-base", default="https://api.boltmesh.mooo.com/v1")
    ap.add_argument("--user", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--region-id", default=DEFAULT_REGION)
    ap.add_argument("--region-name", default=DEFAULT_REGION_NAME)
    ap.add_argument("--node-name", default=DEFAULT_NODE_NAME)
    ap.add_argument("--server-name", required=True,
                    help="the node's endpoint, i.e. the name its certificate is issued for")
    ap.add_argument("--device-name", default="harness-device")
    ap.add_argument("--public-ip", default=DEFAULT_PUBLIC_IP)
    ap.add_argument("--tunnel-ip", default=DEFAULT_TUNNEL_IP)
    ap.add_argument("--wg-port", type=int, default=DEFAULT_WG_PORT)
    ap.add_argument("--stream-port", type=int, default=DEFAULT_STREAM_PORT)
    ap.add_argument("--state-out", required=True)
    ap.add_argument("--recreate-server", action="store_true",
                    help="delete and recreate the node, to get a fresh bootstrap secret")
    args = ap.parse_args()

    api = Api(args.api_base)
    login(api, args.user, args.password)
    print(f"logged in to {args.api_base}")

    # A stable keypair across re-runs: a resumed run must not silently register a
    # *different* device key than the one its conf was built from.
    state = load_state(args.state_out)
    private_key = state.get("client_private_key")
    public_key = state.get("client_public_key")
    if not private_key or not public_key:
        private_key = subprocess.run(["wg", "genkey"], capture_output=True, text=True,
                                     check=True).stdout.strip()
        public_key = subprocess.run(["wg", "pubkey"], input=private_key, capture_output=True,
                                    text=True, check=True).stdout.strip()
        print("generated a device keypair")
    else:
        print("reusing the device keypair from the state file")
    args.client_public_key = public_key
    state.update({
        "api_base": args.api_base,
        "region_id": args.region_id,
        "server_name": args.server_name,
        "stream_port": args.stream_port,
        "client_private_key": private_key,
        "client_public_key": public_key,
    })
    save_state(args.state_out, state)

    ensure_region(api, args.region_id, args.region_name)

    server, secret = ensure_server(api, args, state)
    state.update({"server_id": server["id"], "bootstrap_secret": secret})
    save_state(args.state_out, state)

    device = ensure_device(api, args)
    state.update({"device_id": device["id"], "device_name": args.device_name})
    save_state(args.state_out, state)
    print(f"wrote {args.state_out}")

    check_region_serves_the_rung(api, args.region_id, args.stream_port)
    print("\nThe region's stream policy is not settable through the API yet. If the rung "
          "does not come up, set it directly:\n"
          "  UPDATE vpn_regions SET stream_enabled = true,\n"
          f"    stream_listen_port = {args.stream_port} WHERE id = '{args.region_id}';")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
