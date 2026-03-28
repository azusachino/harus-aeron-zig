# Counters Checker — External Reader Validation

**Branch:** fix/counters-metadata-parity
**Started:** 2026-03-28
**Status:** DONE

## Summary

Standalone Java CountersChecker reads cnc.dat independently via CncFileDescriptor,
validates counter lookup by type id, registration id, channel key, and counter id
across the full counters surface. All 6 required types validated.

## Key files
- `deploy/CountersChecker.java` — standalone external counter validator
- `deploy/InteropSmoke.java` — holds connection via marker-file coordination
- `deploy/entrypoint-java.sh` — concurrent execution with marker cleanup
- `deploy/Dockerfile.java-aeron` — compiles both Java files

## Findings during implementation
- CnC layout and offset computation match between Zig and Java perfectly
- Counter allocation to CnC-backed buffers is correct
- Timing race: InteropSmoke must hold its Aeron connection while CountersChecker validates
- Solved with marker-file coordination (/tmp/smoke-ready, /tmp/checker-done)
