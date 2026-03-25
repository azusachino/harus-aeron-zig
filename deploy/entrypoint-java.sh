#!/bin/sh
set -e

# Use /dev/shm/aeron as the Aeron standard for Linux
AERON_DIR_PATH="${AERON_DIR:-/dev/shm/aeron}"

echo "[CLIENT] Starting Java Client. Aeron Dir: $AERON_DIR_PATH"

# Fail fast if cnc.dat is not present
if [ ! -f "$AERON_DIR_PATH/cnc.dat" ]; then
    echo "[CLIENT] ERROR: cnc.dat NOT FOUND in $AERON_DIR_PATH (Driver not ready or shm not shared)"
    ls -la "$AERON_DIR_PATH" || echo "[CLIENT] Could not even list $AERON_DIR_PATH"
    exit 1
fi

echo "[CLIENT] Found cnc.dat: $(ls -l $AERON_DIR_PATH/cnc.dat)"

# Run the Java subscriber
# Use only the standard -Daeron.dir property for clarity
exec java \
    -Daeron.dir="$AERON_DIR_PATH" \
    -cp /aeron-all.jar \
    io.aeron.samples.BasicSubscriber
