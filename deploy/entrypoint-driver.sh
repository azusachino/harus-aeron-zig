#!/bin/sh
set -e

# Use /dev/shm/aeron as the Aeron standard for Linux
AERON_DIR_PATH="${AERON_DIR:-/dev/shm/aeron}"

echo "[DRIVER] Using Aeron Dir: $AERON_DIR_PATH"

# Fail fast if we can't create/access the directory
mkdir -p "$AERON_DIR_PATH" || { echo "[DRIVER] ERROR: Could not create $AERON_DIR_PATH"; exit 1; }

# Run the driver
# Passing --aeron-dir explicitly to be certain
exec /app/aeron-driver --aeron-dir="$AERON_DIR_PATH"
