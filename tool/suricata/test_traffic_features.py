#!/usr/bin/env python3
"""Self-tests for the traffic-feature extractor's statistics.

The extractor is a measurement tool, so a mistake in it is a wrong number that
looks authoritative. These cover the pure functions — mean, standard deviation,
entropy, size bins, cadence and labelling — with hand-checked inputs. They need
no root, no tshark and no capture. Run directly:

    python3 tool/suricata/test_traffic_features.py
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, _HERE / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


features = _load("suricata_traffic_features", "traffic_features.py")


class StatsTest(unittest.TestCase):
    def test_mean(self) -> None:
        self.assertEqual(features.mean([]), 0.0)
        self.assertEqual(features.mean([1, 2, 3]), 2.0)

    def test_population_stdev(self) -> None:
        # Classic worked example: mean 5, variance 4, stdev 2.
        self.assertEqual(features.pstdev([2, 4, 4, 4, 5, 5, 7, 9]), 2.0)
        self.assertEqual(features.pstdev([]), 0.0)

    def test_entropy_bounds(self) -> None:
        self.assertEqual(features.shannon_entropy(b""), 0.0)
        self.assertEqual(features.shannon_entropy(b"\x00" * 64), 0.0)
        self.assertEqual(features.shannon_entropy(b"ab"), 1.0)
        self.assertAlmostEqual(features.shannon_entropy(bytes(range(256))), 8.0, places=9)

    def test_top_bins(self) -> None:
        values = [0, 1, 15, 16, 17, 31, 32]
        # 3 values land in bin 0, 3 in bin 16, 1 in bin 32; ties break on bin.
        self.assertEqual(features.top_bins(values, 16), [(0, 3), (16, 3), (32, 1)])
        with self.assertRaises(ValueError):
            features.top_bins(values, 0)

    def test_dominant_interval(self) -> None:
        # 1s repeats; the lone 25s does not win, and sub-grid jitter is dropped.
        self.assertEqual(features.dominant_interval([1.0, 1.02, 25.0], tolerance=1.0), 1.0)
        self.assertEqual(features.dominant_interval([0.01, 0.02], tolerance=1.0), None)
        self.assertEqual(features.dominant_interval([5.0], tolerance=1.0), None)
        self.assertIsNone(features.dominant_interval([]))

    def test_label_flow(self) -> None:
        node = "192.168.1.115"
        ports = {"native": 51820, "awg": 51821, "stream": 443}
        self.assertEqual(
            features.label_flow("UDP", [("192.168.1.113", 5000), (node, 51820)], node, ports),
            "native")
        self.assertEqual(
            features.label_flow("UDP", [(node, 51821), ("192.168.1.113", 5001)], node, ports),
            "awg")
        self.assertEqual(
            features.label_flow("TCP", [("192.168.1.113", 5002), (node, 443)], node, ports),
            "stream")
        # A node flow on another port is not a rung.
        self.assertEqual(
            features.label_flow("TCP", [(node, 8443), ("93.177.140.197", 443)], node, ports),
            "node-other")
        # Neither endpoint is the node.
        self.assertEqual(
            features.label_flow("UDP", [("10.0.0.1", 53), ("10.0.0.2", 4000)], node, ports),
            "baseline")


class SummarizeTest(unittest.TestCase):
    def test_summarize_shapes(self) -> None:
        packets = [
            features.Packet(0.0, ("a", 1), ("b", 2), "UDP", 100, b"\x00" * 8),
            features.Packet(1.0, ("b", 2), ("a", 1), "UDP", 300, b"\xff" * 8),
            features.Packet(2.0, ("a", 1), ("b", 2), "UDP", 200, b"\xaa" * 8),
        ]
        summary = features.summarize(packets, "native")
        self.assertEqual(summary.packets, 3)
        self.assertEqual(summary.bytes_total, 600)
        self.assertEqual(summary.first_size, 100)
        self.assertEqual(summary.size_min, 100)
        self.assertEqual(summary.size_max, 300)
        # Forward is the first packet's direction: a->b, so 100+200.
        self.assertEqual(summary.bytes_forward, 300)
        self.assertEqual(summary.bytes_reverse, 300)


if __name__ == "__main__":
    unittest.main(verbosity=2)
