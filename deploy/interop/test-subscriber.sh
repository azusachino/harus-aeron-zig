#!/usr/bin/env bash
# Runs Java Aeron BasicSubscriber, expects $MESSAGE_COUNT messages on $CHANNEL/$STREAM_ID
# Times out after $TIMEOUT_SEC seconds. Exits 0 if count matches, 1 otherwise.
set -euo pipefail

: "${CHANNEL:=aeron:udp?endpoint=localhost:40123}"
: "${STREAM_ID:=1001}"
: "${MESSAGE_COUNT:=1000}"
: "${TIMEOUT_SEC:=30}"
: "${AERON_DIR:=/dev/shm/aeron}"

# Run subscriber with timeout, count received messages
timeout "$TIMEOUT_SEC" java -cp /opt/aeron/aeron-all.jar \
  -Daeron.dir="$AERON_DIR" \
  io.aeron.samples.RateSubscriber \
  "$CHANNEL" "$STREAM_ID" 2>&1 | tee /tmp/sub-output.log &
SUB_PID=$!

# Wait for subscriber to finish or timeout
wait $SUB_PID
SUB_EXIT=$?

if [ $SUB_EXIT -ne 0 ]; then
  echo "Subscriber exited with code $SUB_EXIT"
  exit 1
fi

RECEIVED=$(grep -c "Message received" /tmp/sub-output.log || echo "0")
echo "Received $RECEIVED messages (expected $MESSAGE_COUNT)"

if [ "$RECEIVED" -ge "$MESSAGE_COUNT" ]; then
  echo "PASS"
  exit 0
else
  echo "FAIL: expected $MESSAGE_COUNT, got $RECEIVED"
  exit 1
fi
