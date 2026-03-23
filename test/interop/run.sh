#!/usr/bin/env bash
# test/interop/run.sh — gated on AERON_INTEROP=1
set -euo pipefail

if [ "${AERON_INTEROP:-0}" != "1" ]; then
  echo "SKIP: set AERON_INTEROP=1 to run Java interop tests"
  exit 0
fi

# Download aeron-all.jar if not already present
AERON_VERSION="${AERON_VERSION:-1.44.1}"
JAR="test/interop/aeron-all.jar"
if [ ! -f "$JAR" ]; then
  echo "Downloading aeron-all-${AERON_VERSION}.jar..."
  curl -fsSL -o "$JAR" \
    "https://repo1.maven.org/maven2/io/aeron/aeron-all/${AERON_VERSION}/aeron-all-${AERON_VERSION}.jar"
fi

echo "=== Interop test: Java pub -> Zig sub ==="
# We need to build the Docker image first because we're on Mac
docker compose -f test/interop/docker-compose.yml build zig-sub
docker compose -f test/interop/docker-compose.yml up --abort-on-container-exit
echo "=== PASS ==="
