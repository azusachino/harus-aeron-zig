#!/usr/bin/env -S uv run --script
"""Report adoption of the vendored upstream Aeron test suite."""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / "vendor" / "aeron"
MAP = ROOT / "test" / "upstream_map.jsonl"

MODULES = ("aeron-client", "aeron-driver", "aeron-archive", "aeron-cluster")


def upstream_tests() -> dict[str, list[Path]]:
    return {
        module: sorted((UPSTREAM / module / "src" / "test").rglob("*.java"))
        for module in MODULES
    }


def adopted() -> Counter[str]:
    counts: Counter[str] = Counter()
    if not MAP.exists():
        return counts
    for raw in re.findall(r"\{[^{}]*\}", MAP.read_text(), flags=re.DOTALL):
        entry = json.loads(raw)
        if entry.get("status") == "done":
            counts[entry.get("layer", "unknown")] += 1
    return counts


def report() -> int:
    tests = upstream_tests()
    adopted_counts = adopted()
    print("Aeron upstream test adoption")
    print("module              upstream Java tests   mapped Zig entries")
    print("------------------  --------------------  ------------------")
    for module, paths in tests.items():
        layer = module.removeprefix("aeron-")
        print(f"{module:18}  {len(paths):20}  {adopted_counts[layer]:18}")

    print("\nRequired Cluster conformance tests")
    required = {
        "AeronClusterTest",
        "EgressPollerTest",
        "SessionEventCodecCompatibilityTest",
        "IngressAdapterTest",
    }
    for name in sorted(required):
        print(f"  required  {name}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("report",), default="report", nargs="?")
    args = parser.parse_args()
    return report() if args.action == "report" else 2


if __name__ == "__main__":
    raise SystemExit(main())
