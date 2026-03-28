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

rm -f /tmp/smoke-ready /tmp/checker-done

JAVA_OPTS="--add-opens java.base/jdk.internal.misc=ALL-UNNAMED --add-opens java.base/java.util.zip=ALL-UNNAMED"

# Run InteropSmoke in background — it establishes pub/sub and populates counters.
java $JAVA_OPTS \
    -Daeron.dir="$AERON_DIR_PATH" \
    -Daeron.sample.messageCount="${MSG_COUNT:-10}" \
    -cp /aeron-all.jar:/interop \
    InteropSmoke &
SMOKE_PID=$!

# Run CountersChecker in foreground — it polls for counters to appear, then validates.
java $JAVA_OPTS \
    -Daeron.dir="$AERON_DIR_PATH" \
    -cp /aeron-all.jar:/interop \
    CountersChecker
CHECKER_EXIT=$?

# Wait for InteropSmoke to finish.
wait $SMOKE_PID
SMOKE_EXIT=$?

# Report and exit with first non-zero.
if [ "$SMOKE_EXIT" -ne 0 ]; then
    echo "[CLIENT] InteropSmoke FAILED (exit=$SMOKE_EXIT)"
    exit $SMOKE_EXIT
fi

if [ "$CHECKER_EXIT" -ne 0 ]; then
    echo "[CLIENT] CountersChecker FAILED (exit=$CHECKER_EXIT)"
    exit $CHECKER_EXIT
fi

echo "[CLIENT] All checks passed"
