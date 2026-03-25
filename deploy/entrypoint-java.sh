#!/bin/sh
set -e

# Ensure /dev/shm/aeron exists (at runtime, not build time)
mkdir -p /dev/shm/aeron
mkdir -p /aeron_data

# Create symlinks for Java Aeron client compatibility
ln -sf /dev/shm/aeron /dev/shm/aeron-root 2>/dev/null || true
ln -sf /aeron_data /aeron_data_root 2>/dev/null || true

# Run the Java subscriber
exec java -cp /aeron-all.jar io.aeron.samples.BasicSubscriber
