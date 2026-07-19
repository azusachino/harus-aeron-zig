#!/usr/bin/env -S uv run --script
"""Run the BTC_USDT cluster sample scenarios.

The script deliberately owns orchestration policy; Make remains focused on
building and checking the Zig module. Each mode must provide a real
three-member Compose topology before `up` is allowed to run.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMPOSE_DIR = ROOT / "deploy" / "trading"
MODES = ("zig", "java", "mixed")


def compose_file(mode: str) -> Path:
    return COMPOSE_DIR / f"docker-compose.{mode}.yml"


def compose_command() -> list[str]:
    if shutil.which("docker") and shutil.which("docker-compose"):
        return ["docker-compose"]
    if shutil.which("docker"):
        return ["docker", "compose"]
    if shutil.which("podman-compose"):
        return ["podman-compose"]
    raise SystemExit("no Docker Compose or podman-compose executable found")


def require_topology(mode: str) -> Path:
    path = compose_file(mode)
    if not path.exists():
        raise SystemExit(
            f"{mode} topology is not implemented yet: expected {path.relative_to(ROOT)}"
        )
    return path


def run(mode: str, action: str) -> int:
    path = require_topology(mode)
    if action == "soak":
        cleanup = subprocess.run(
            compose_command() + ["-f", str(path), "down", "--remove-orphans"],
            cwd=ROOT,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    if mode == "java" and action in ("up", "soak"):
        build_command = [
            "nix",
            "develop",
            "--command",
            "zig",
            "build",
            "-Dtarget=aarch64-linux",
        ]
        if action == "soak":
            build_command.append("-Doptimize=ReleaseFast")
        build_command.append("examples")
        build = subprocess.run(
            build_command,
            cwd=ROOT,
            check=False,
        )
        if build.returncode != 0:
            return build.returncode
    compose_action = "up" if action == "soak" else action
    command = compose_command() + ["-f", str(path), compose_action]
    if action in ("up", "soak"):
        command += ["--build", "--abort-on-container-exit"]
    elif action == "down":
        command += ["--remove-orphans"]
    environment = None
    if action == "soak":
        environment = {
            **os.environ,
            "ORDER_COUNT": os.environ.get("TRADING_SOAK_MESSAGES", "500"),
            "START_DELAY_MS": os.environ.get("TRADING_SOAK_START_DELAY_MS", "5000"),
            "HOLD_OPEN_MS": os.environ.get("TRADING_SOAK_HOLD_OPEN_MS", "30000"),
            "OFFER_TIMEOUT_MS": os.environ.get("TRADING_SOAK_OFFER_TIMEOUT_MS", "600000"),
            "QUIET": "1",
        }
    return subprocess.run(command, cwd=ROOT, env=environment, check=False).returncode


def main() -> int:
    parser = argparse.ArgumentParser(
        description="BTC_USDT cluster sample runner; soak uses ReleaseFast and configurable message counts"
    )
    parser.add_argument("action", choices=("plan", "test", "up", "soak", "down", "config"))
    parser.add_argument("--mode", choices=MODES, default=None)
    args = parser.parse_args()

    if args.action == "plan":
        print("BTC_USDT cluster sample modes:")
        for mode in MODES:
            path = compose_file(mode)
            status = "ready" if path.exists() else "blocked: topology not implemented"
            print(f"  {mode:5} {status} ({path.relative_to(ROOT)})")
        return 0

    if args.mode is None:
        parser.error("--mode is required for test, up, down, and config")

    if args.action == "test":
        if args.mode == "zig":
            return subprocess.run(
                ["nix", "develop", "--command", "zig", "build", "test-examples"],
                cwd=ROOT,
                check=False,
            ).returncode
        if args.mode == "java":
            with tempfile.TemporaryDirectory(prefix="btc-usdt-java-") as output:
                sources = [
                    ROOT / "examples/trading/java/TradingOrderBook.java",
                    ROOT / "examples/trading/java/TradingOrderBookTest.java",
                    ROOT / "examples/trading/java/TradingSample.java",
                ]
                compile_result = subprocess.run(
                    ["javac", "-d", output, *(str(source) for source in sources)],
                    cwd=ROOT,
                    check=False,
                )
                if compile_result.returncode != 0:
                    return compile_result.returncode
                for main_class in ("trading.TradingOrderBookTest", "trading.TradingSample"):
                    result = subprocess.run(["java", "-cp", output, main_class], cwd=ROOT, check=False)
                    if result.returncode != 0:
                        return result.returncode
                return 0
        raise SystemExit("mixed sample tests require a real three-process topology")

    path = require_topology(args.mode)
    if args.action == "config":
        return subprocess.run(compose_command() + ["-f", str(path), "config"], cwd=ROOT).returncode
    return run(args.mode, args.action)


if __name__ == "__main__":
    sys.exit(main())
