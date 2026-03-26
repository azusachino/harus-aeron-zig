#!/bin/sh
set -e

# Use /dev/shm/aeron as the Aeron standard for Linux
AERON_DIR_PATH="${AERON_DIR:-/dev/shm/aeron}"

echo "[CLIENT] Starting Java Client. Aeron Dir: $AERON_DIR_PATH"

deadline=30
while [ ! -f "$AERON_DIR_PATH/cnc.dat" ] && [ "$deadline" -gt 0 ]; do
    sleep 1
    deadline=$((deadline - 1))
done

if [ ! -f "$AERON_DIR_PATH/cnc.dat" ]; then
    echo "[CLIENT] ERROR: cnc.dat NOT FOUND in $AERON_DIR_PATH after waiting"
    ls -la "$AERON_DIR_PATH" || echo "[CLIENT] Could not even list $AERON_DIR_PATH"
    exit 1
fi

echo "[CLIENT] Found cnc.dat: $(ls -l $AERON_DIR_PATH/cnc.dat)"

# Run the Java subscriber
# Use only the standard -Daeron.dir property for clarity
exec java \
    --add-opens java.base/jdk.internal.misc=ALL-UNNAMED \
    --add-opens java.base/java.util.zip=ALL-UNNAMED \
    -Daeron.dir="$AERON_DIR_PATH" \
    -cp /aeron-all.jar \
    io.aeron.samples.BasicSubscriber
