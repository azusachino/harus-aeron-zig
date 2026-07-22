#!/usr/bin/env -S uv run --script
"""Run the BTC_USDT cluster sample scenarios.

The script deliberately owns orchestration policy; Make remains focused on
building and checking the Zig module. Each mode must provide a real
three-member Compose topology before `up` is allowed to run.
"""

from __future__ import annotations

import argparse
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMPOSE_DIR = ROOT / "deploy" / "trading"
MODES = ("zig", "java", "mixed")


def compose_file(mode: str) -> Path:
    return COMPOSE_DIR / f"docker-compose.{mode}.yml"


def cluster_compose_file(mode: str) -> Path:
    return COMPOSE_DIR / f"docker-compose.{mode}-cluster.yml"


def project_name(mode: str, cluster: bool = False) -> str:
    suffix = "-cluster" if cluster else "-clients"
    project = f"aeron-{mode}{suffix}"
    run_suffix = os.environ.get("TRADING_PROJECT_SUFFIX", "").strip()
    if run_suffix:
        sanitized = "".join(character if character.isalnum() or character in "-_" else "-" for character in run_suffix)
        project = f"{project}-{sanitized.strip('-_')}"
    return project


def compose_command() -> list[str]:
    configured = os.environ.get("COMPOSE")
    if configured:
        return shlex.split(configured)
    if shutil.which("docker") and shutil.which("docker-compose"):
        return ["docker-compose"]
    if shutil.which("docker"):
        return ["docker", "compose"]
    if shutil.which("podman-compose"):
        return ["podman-compose"]
    raise SystemExit("no Compose executable found; set COMPOSE to the Compose command")


def require_topology(mode: str) -> Path:
    path = compose_file(mode)
    if not path.exists():
        raise SystemExit(
            f"{mode} topology is not implemented yet: expected {path.relative_to(ROOT)}"
        )
    return path


def ensure_java_artifact() -> None:
    cache_path = ROOT / "test" / "interop" / "aeron-all.jar"
    if cache_path.exists():
        return
    jar_dir = ROOT / "vendor" / "aeron" / "aeron-all" / "build" / "libs"
    jars = list(jar_dir.glob("aeron-all-*.jar"))
    if not jars:
        result = subprocess.run(
            [str(ROOT / "vendor" / "aeron" / "gradlew"), "aeron-all:jar", "--no-daemon"],
            cwd=ROOT / "vendor" / "aeron",
            check=False,
        )
        if result.returncode != 0:
            raise SystemExit("failed to build the vendored Aeron all-in-one jar")
        jars = list(jar_dir.glob("aeron-all-*.jar"))
    if not jars:
        raise SystemExit("vendored Aeron build produced no aeron-all jar")
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(jars[0], cache_path)


def compose_down(mode: str, cluster: bool = False) -> int:
    path = cluster_compose_file(mode) if cluster else compose_file(mode)
    return subprocess.run(
        compose_command()
        + [
            "-p",
            project_name(mode, cluster=cluster),
            "-f",
            str(path),
            "down",
            "--remove-orphans",
        ],
        cwd=ROOT,
        check=False,
    ).returncode


def run_replay_proof() -> int:
    mode = "zig"
    expected_orders = int(os.environ.get("TRADING_SOAK_MESSAGES", "3")) * 2
    result = run(mode, "soak")
    if result != 0:
        compose_down(mode, cluster=False)
        compose_down(mode, cluster=True)
        return result

    cluster_path = cluster_compose_file(mode)
    try:
        restart = subprocess.run(
            compose_command()
            + [
                "-p",
                project_name(mode, cluster=True),
                "-f",
                str(cluster_path),
                "up",
                "-d",
                "--no-deps",
                "--no-build",
                "--force-recreate",
                "zig-node-1",
            ],
            cwd=ROOT,
            check=False,
        )
        if restart.returncode != 0:
            return restart.returncode

        deadline = time.monotonic() + float(os.environ.get("TRADING_REPLAY_PROOF_TIMEOUT_S", "30"))
        replayed_orders: int | None = None
        while time.monotonic() < deadline:
            logs = subprocess.run(
                compose_command()
                + [
                    "-p",
                    project_name(mode, cluster=True),
                    "-f",
                    str(cluster_path),
                    "logs",
                    "--tail",
                    "100",
                    "zig-node-1",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            matches = re.findall(r"ZIG_CLUSTER_REPLAY member=1 orders=(\d+)", logs.stdout + logs.stderr)
            if matches:
                replayed_orders = int(matches[-1])
                break
            time.sleep(1)

        if replayed_orders != expected_orders:
            print(
                f"replay proof failed: member 1 restored {replayed_orders!r} orders, "
                f"expected {expected_orders}",
                file=sys.stderr,
            )
            return 1
        print(f"ZIG_CLUSTER_REPLAY_PROOF_OK member=1 orders={replayed_orders}")
        return 0
    finally:
        compose_down(mode, cluster=False)
        compose_down(mode, cluster=True)


def run_mixed_log_proof() -> int:
    mode = "mixed"
    expected_orders = int(os.environ.get("TRADING_SOAK_MESSAGES", "3")) * 2
    result = run(mode, "soak")
    if result != 0:
        compose_down(mode, cluster=False)
        compose_down(mode, cluster=True)
        return result

    cluster_path = cluster_compose_file(mode)
    try:
        restart = subprocess.run(
            compose_command()
            + [
                "-p",
                project_name(mode, cluster=True),
                "-f",
                str(cluster_path),
                "up",
                "-d",
                "--no-deps",
                "--no-build",
                "--force-recreate",
                "zig-node-2",
            ],
            cwd=ROOT,
            check=False,
        )
        if restart.returncode != 0:
            return restart.returncode

        deadline = time.monotonic() + float(os.environ.get("TRADING_REPLAY_PROOF_TIMEOUT_S", "30"))
        log_entries: int | None = None
        replayed_orders: int | None = None
        while time.monotonic() < deadline:
            logs = subprocess.run(
                compose_command()
                + [
                    "-p",
                    project_name(mode, cluster=True),
                    "-f",
                    str(cluster_path),
                    "logs",
                    "--tail",
                    "100",
                    "zig-node-2",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            ready_lines = re.findall(
                r"ZIG_MIXED_MEMBER_READY .* log_entries=(\d+) replayed_orders=(\d+)",
                logs.stdout + logs.stderr,
            )
            if ready_lines:
                log_entries = int(ready_lines[-1][0])
                replayed_orders = int(ready_lines[-1][1])
                break
            time.sleep(1)

        if log_entries is None or replayed_orders is None or replayed_orders < expected_orders:
            print(
                f"mixed log proof failed: restored {log_entries!r} records and "
                f"replayed {replayed_orders!r} orders, expected at least {expected_orders}",
                file=sys.stderr,
            )
            return 1
        print(
            f"ZIG_MIXED_LOG_PROOF_OK member=2 log_entries={log_entries} "
            f"replayed_orders={replayed_orders} minimum={expected_orders}"
        )
        return 0
    finally:
        compose_down(mode, cluster=False)
        compose_down(mode, cluster=True)


def run(mode: str, action: str) -> int:
    path = require_topology(mode)
    cluster_path = cluster_compose_file(mode)
    if action in ("up", "soak", "down") and not cluster_path.exists():
        raise SystemExit(
            f"{mode} cluster topology is not implemented yet: expected {cluster_path.relative_to(ROOT)}"
        )
    if action == "soak":
        compose_down(mode, cluster=False)
    if mode in ("java", "zig", "mixed") and action in ("up", "soak"):
        ensure_java_artifact()
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
        cluster = subprocess.run(
            compose_command()
            + ["-p", project_name(mode, cluster=True), "-f", str(cluster_path), "up", "--build", "-d"],
            cwd=ROOT,
            check=False,
        )
        if cluster.returncode != 0:
            return cluster.returncode
    compose_action = "up" if action == "soak" else action
    command = compose_command() + ["-p", project_name(mode), "-f", str(path), compose_action]
    if action in ("up", "soak"):
        command += ["--build"]
        if mode in ("java", "zig", "mixed"):
            command += ["java-client", "zig-client"]
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
            "RESPONSE_TIMEOUT_MS": os.environ.get("TRADING_SOAK_RESPONSE_TIMEOUT_MS", "600000"),
            "CONNECT_MAX_ITERATIONS": os.environ.get("TRADING_SOAK_CONNECT_MAX_ITERATIONS", "10000000"),
            "QUIET": "1",
        }
    hard_timeout_ms = None
    if action == "soak":
        hard_timeout_ms = int(os.environ.get("TRADING_SOAK_HARD_TIMEOUT_MS", "900000"))
    try:
        result = subprocess.run(
            command,
            cwd=ROOT,
            env=environment,
            check=False,
            timeout=None if hard_timeout_ms is None else hard_timeout_ms / 1000,
        )
    except subprocess.TimeoutExpired:
        print(
            f"{mode} soak exceeded TRADING_SOAK_HARD_TIMEOUT_MS={hard_timeout_ms}; "
            "cleaning both Compose projects",
            file=sys.stderr,
        )
        compose_down(mode, cluster=False)
        compose_down(mode, cluster=True)
        return 124
    if action == "down" and mode in ("java", "zig", "mixed"):
        cluster_result = compose_down(mode, cluster=True)
        return result.returncode or cluster_result
    return result.returncode


def main() -> int:
    parser = argparse.ArgumentParser(
        description="BTC_USDT cluster sample runner; soak uses ReleaseFast and configurable message counts"
    )
    parser.add_argument(
        "action",
        choices=("plan", "test", "up", "soak", "replay-proof", "mixed-log-proof", "down", "config", "ensure-java-artifact"),
    )
    parser.add_argument("--mode", choices=MODES, default=None)
    args = parser.parse_args()

    if args.action == "ensure-java-artifact":
        ensure_java_artifact()
        return 0

    if args.action == "plan":
        print("BTC_USDT cluster sample modes:")
        for mode in MODES:
            path = compose_file(mode)
            status = "ready" if path.exists() else "blocked: topology not implemented"
            print(f"  {mode:5} {status} ({path.relative_to(ROOT)})")
        return 0

    if args.mode is None:
        parser.error("--mode is required for test, up, soak, replay-proof, mixed-log-proof, down, and config")

    if args.action == "replay-proof":
        if args.mode != "zig":
            parser.error("replay-proof currently requires --mode zig")
        return run_replay_proof()
    if args.action == "mixed-log-proof":
        if args.mode != "mixed":
            parser.error("mixed-log-proof currently requires --mode mixed")
        return run_mixed_log_proof()

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
        return subprocess.run(
            compose_command() + ["-p", project_name(args.mode), "-f", str(path), "config"],
            cwd=ROOT,
        ).returncode
    return run(args.mode, args.action)


if __name__ == "__main__":
    sys.exit(main())
