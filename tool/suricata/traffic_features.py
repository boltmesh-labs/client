#!/usr/bin/env python3
"""Per-flow traffic-analysis features for a Suricata run's pcap.

This is the quantifiable half of the traffic-analysis tier: it reads the capture
`run.sh` already saves, groups packets into flows, and prints the metadata a
middlebox sees without reading any protocol content — packet sizes, direction
volumes, inter-arrival times, cadence, and payload entropy.

The feature vector deliberately excludes ports and IP addresses; those are used
only to *label* a flow against the node and rung map we know from the run. A
detector that keyed on the port would be doing port analysis, not traffic
analysis, so the separation is the point.

Scope, stated honestly: one short capture with a handful of flows is enough to
show that a tunnel's shape is observable and to compare rungs, not to claim
classifier accuracy. A real VPN-classifier result needs a labelled baseline and
cross-validation over many flows. See README.md.

Needs `tshark` on PATH. Run it directly:

    python3 tool/suricata/traffic_features.py --pcap run/pcap/ens160.pcap --node 192.168.1.115
"""

from __future__ import annotations

import argparse
import math
import shutil
import subprocess
from collections import Counter
from dataclasses import dataclass, field

# --- pure statistics (unit-tested without tshark) ---------------------------


def mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def pstdev(values: list[float]) -> float:
    """Population standard deviation; feature extraction, not inference."""
    if not values:
        return 0.0
    average = mean(values)
    return math.sqrt(sum((value - average) ** 2 for value in values) / len(values))


def shannon_entropy(data: bytes) -> float:
    """Shannon entropy in bits/byte, 0.0 (uniform bytes) .. 8.0 (random)."""
    if not data:
        return 0.0
    counts = Counter(data)
    total = len(data)
    return -sum((count / total) * math.log2(count / total) for count in counts.values())


def top_bins(values: list[int], width: int, limit: int = 3) -> list[tuple[int, int]]:
    """Most common size bins as (bin_start, count), largest count first."""
    if width <= 0:
        raise ValueError("bin width must be positive")
    counts = Counter((value // width) * width for value in values)
    return sorted(counts.items(), key=lambda item: (-item[1], item[0]))[:limit]


def dominant_interval(values: list[float], tolerance: float = 1.0) -> float | None:
    """The most common inter-arrival interval, if any repeats.

    Values are rounded to a `tolerance` grid before counting, so a keepalive is
    found even when jitter smears it. Intervals below one grid step are dropped:
    a burst of back-to-back packets is not a cadence. Returns None otherwise.
    """
    if not values:
        return None
    counts = Counter(
        round(value / tolerance) * tolerance for value in values if value >= tolerance
    )
    if not counts:
        return None
    interval, count = max(counts.items(), key=lambda item: item[1])
    return interval if count >= 2 else None


def label_flow(
    proto: str, endpoints: list[tuple[str, int]], node: str, ports: dict[str, int]
) -> str:
    """Name the rung from the known run topology, or 'baseline'.

    Labels are ground truth only; no feature is derived from these addresses.
    """
    for ip, port in endpoints:
        if ip != node:
            continue
        if proto == "UDP" and port == ports["native"]:
            return "native"
        if proto == "UDP" and port == ports["awg"]:
            return "awg"
        if proto == "TCP" and port == ports["stream"]:
            return "stream"
    if any(ip == node for ip, _ in endpoints):
        return "node-other"
    return "baseline"


# --- capture reading and flow grouping --------------------------------------

_TSHARK_FIELDS = (
    "frame.time_epoch", "ip.src", "ip.dst", "ip.proto",
    "udp.srcport", "udp.dstport", "udp.length", "udp.payload",
    "tcp.srcport", "tcp.dstport", "tcp.len", "tcp.payload",
)
_PROTO_NAMES = {"6": "TCP", "17": "UDP"}


@dataclass
class Packet:
    time: float
    src: tuple[str, int]
    dst: tuple[str, int]
    proto: str
    payload_len: int
    payload: bytes


def read_packets(pcap: str) -> list[Packet]:
    """Extract per-packet transport records from a pcap via tshark."""
    if shutil.which("tshark") is None:
        raise SystemExit("traffic_features: tshark is required but not installed")
    command = ["tshark", "-r", pcap, "-T", "fields", "-E", "separator=\t",
               "-E", "occurrence=f"]
    for name in _TSHARK_FIELDS:
        command += ["-e", name]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SystemExit(f"traffic_features: tshark failed on {pcap}: {result.stderr.strip()}")

    packets: list[Packet] = []
    for row in result.stdout.splitlines():
        fields = row.split("\t")
        if len(fields) != len(_TSHARK_FIELDS):
            continue
        (ts, src_ip, dst_ip, proto_num, usp, udp_, ulen, upay,
         tsp, tdp, tlen, tpay) = fields
        proto = _PROTO_NAMES.get(proto_num)
        if proto is None or not src_ip or not dst_ip:
            continue
        if proto == "UDP":
            if not ulen:
                continue
            src_port, dst_port = int(usp or 0), int(udp_ or 0)
            payload_len = int(ulen) - 8
            payload = bytes.fromhex(upay) if upay else b""
        else:
            if not tlen or int(tlen) == 0:
                continue  # no TCP payload (SYN/ACK/FIN) contributes no data
            src_port, dst_port = int(tsp or 0), int(tdp or 0)
            payload_len = int(tlen)
            payload = bytes.fromhex(tpay) if tpay else b""
        if payload_len < 0:
            continue
        packets.append(Packet(float(ts), (src_ip, src_port), (dst_ip, dst_port),
                              proto, payload_len, payload))
    return packets


def group_flows(packets: list[Packet]) -> dict[tuple, list[Packet]]:
    """Group by (proto, unordered endpoint pair)."""
    flows: dict[tuple, list[Packet]] = {}
    for packet in packets:
        endpoints = tuple(sorted((packet.src, packet.dst)))
        flows.setdefault((packet.proto, endpoints), []).append(packet)
    return flows


@dataclass
class FlowSummary:
    label: str
    proto: str
    packets: int
    bytes_total: int
    bytes_forward: int
    bytes_reverse: int
    size_min: int
    size_mean: float
    size_max: int
    size_stdev: float
    first_size: int
    size_bins: list[tuple[int, int]] = field(default_factory=list)
    iat_mean_ms: float = 0.0
    iat_stdev_ms: float = 0.0
    cadence_s: float | None = None
    entropy_mean: float = 0.0


def summarize(flow_packets: list[Packet], label: str) -> FlowSummary:
    flow_packets = sorted(flow_packets, key=lambda p: p.time)
    forward = flow_packets[0].src
    sizes = [p.payload_len for p in flow_packets]
    times = [p.time for p in flow_packets]
    iats = [(b - a) * 1000.0 for a, b in zip(times, times[1:])]
    entropies = [shannon_entropy(p.payload) for p in flow_packets if p.payload]
    bytes_forward = sum(p.payload_len for p in flow_packets if p.src == forward)
    return FlowSummary(
        label=label,
        proto=flow_packets[0].proto,
        packets=len(flow_packets),
        bytes_total=sum(sizes),
        bytes_forward=bytes_forward,
        bytes_reverse=sum(sizes) - bytes_forward,
        size_min=min(sizes),
        size_mean=mean(sizes),
        size_max=max(sizes),
        size_stdev=pstdev([float(s) for s in sizes]),
        first_size=sizes[0],
        size_bins=top_bins(sizes, 16),
        iat_mean_ms=mean(iats),
        iat_stdev_ms=pstdev(iats),
        cadence_s=dominant_interval([value / 1000.0 for value in iats]),
        entropy_mean=mean(entropies),
    )


def build_summaries(packets: list[Packet], node: str, ports: dict[str, int]) -> list[FlowSummary]:
    summaries: list[FlowSummary] = []
    for (proto, endpoints), flow_packets in group_flows(packets).items():
        summaries.append(summarize(flow_packets, label_flow(proto, list(endpoints), node, ports)))
    # Biggest flows first; the tunnels dwarf the baseline in a lab capture.
    summaries.sort(key=lambda s: (-s.bytes_total, s.label))
    return summaries


def format_report(summaries: list[FlowSummary]) -> str:
    lines = [
        "Flows (features exclude ports/IPs; label is ground truth only):",
        f"  {'label':<10} {'proto':<4} {'pkts':>5} {'bytes':>7} "
        f"{'fwd/rev':>13} {'size min/mean/max/sd':>26} {'first':>5} "
        f"{'iat mean/sd ms':>16} {'cad':>6} {'H':>5}",
    ]
    for summary in summaries:
        cadence = f"{summary.cadence_s:.1f}" if summary.cadence_s is not None else "-"
        lines.append(
            f"  {summary.label:<10} {summary.proto:<4} {summary.packets:>5} "
            f"{summary.bytes_total:>7} {summary.bytes_forward:>6}/{summary.bytes_reverse:<6} "
            f"{summary.size_min:>6}/{summary.size_mean:>7.1f}/{summary.size_max:>5}/"
            f"{summary.size_stdev:>6.1f} {summary.first_size:>5} "
            f"{summary.iat_mean_ms:>7.1f}/{summary.iat_stdev_ms:<7.1f} "
            f"{cadence:>6} {summary.entropy_mean:>5.2f}"
        )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pcap", required=True, help="capture to analyze")
    parser.add_argument("--node", required=True, help="the serving node's address")
    parser.add_argument("--native-port", type=int, default=51820)
    parser.add_argument("--awg-port", type=int, default=51821)
    parser.add_argument("--stream-port", type=int, default=443)
    args = parser.parse_args(argv)

    ports = {"native": args.native_port, "awg": args.awg_port, "stream": args.stream_port}
    summaries = build_summaries(read_packets(args.pcap), args.node, ports)
    print(format_report(summaries))
    print()
    print("  bytes_fwd/rev is first-packet -> other, not client -> server.")
    print("  Cadence is the most-repeated inter-arrival interval, rounded to 1s.")
    print("  Compare native/awg size and cadence against the baseline rows.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
