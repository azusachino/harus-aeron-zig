#!/usr/bin/env bash
# Runs Java Aeron BasicPublisher, sends $MESSAGE_COUNT messages to $CHANNEL on $STREAM_ID
# Exits 0 on success, 1 on failure
set -euo pipefail

: "${CHANNEL:=aeron:udp?endpoint=localhost:40123}"
: "${STREAM_ID:=1001}"
: "${MESSAGE_COUNT:=1000}"
: "${AERON_DIR:=/dev/shm/aeron}"

java -cp /opt/aeron/aeron-all.jar \
  -Daeron.dir="$AERON_DIR" \
  io.aeron.samples.StreamingPublisher \
  "$CHANNEL" "$STREAM_ID" "$MESSAGE_COUNT"

echo "Published $MESSAGE_COUNT messages"
exit 0
