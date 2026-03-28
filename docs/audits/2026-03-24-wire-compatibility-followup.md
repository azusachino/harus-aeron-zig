# Wire Compatibility Audit — harus-aeron-zig

**Date**: 2026-03-24
**Auditor**: Codex
**Scope**: Current repository state compared with the official `aeron-io/aeron` project

## Summary

The implementation is now materially stronger than the previous audit:

- `make check` passes.
- `AERON_INTEROP=1 make test-interop` passes.
- The repo now demonstrates a real cross-language path: Java publisher -> Zig subscriber.

That said, this is still a partial Aeron implementation, not a full replacement for the upstream project. The codebase covers the core driver/client transport slice well enough for the current release goal, but it still lacks parity in archive, cluster, transport breadth, and production hardening.

## What Matches Upstream Well

- Frame codecs are laid out with `extern struct` and size assertions.
- The codebase uses explicit allocators throughout.
- The transport/driver/client split mirrors the upstream architecture.
- The release gates now prove the main UDP interop path works end-to-end.
- Unit and integration tests exist for the core client and driver paths.

## Remaining Gaps vs Upstream Aeron

### 1. Archive parity is incomplete

The archive stack is not yet comparable to the real Aeron Archive.

- [src/archive/recorder.zig](/Users/yinchun.pang/Projects/project-github/harus-aeron-zig/src/archive/recorder.zig) still contains TODOs for metadata propagation.
- The archive control path is still simplified relative to upstream SBE-driven control messages.
- Replay is still much closer to an in-memory proof of concept than the file-backed replay pipeline in official Aeron.

### 2. Cluster parity is incomplete

The cluster code is present, but it is not yet the same subsystem as upstream Aeron Cluster.

- The consensus/recovery path is simplified.
- Snapshot/replay/rejoin behavior is still incomplete.
- Operational and failure-mode coverage is much thinner than upstream.

### 3. Transport coverage is narrower than upstream

The driver now speaks UDP and interops with Java on the happy path, but upstream Aeron covers a broader matrix:

- more URI forms,
- richer multicast/control-channel semantics,
- more complete flow-control behavior,
- more fully exercised retransmit handling,
- broader sample and test coverage.

See the official Aeron documentation for samples and channel configuration:

- https://github.com/aeron-io/aeron/wiki/Running-Samples
- https://github.com/real-logic/aeron/wiki/Channel-Configuration

### 4. Interop coverage is still one-directional

The current smoke test proves Java pub -> Zig sub.

Still missing:

- Zig pub -> Java sub smoke test.
- Archive interop.
- Cluster interop.
- Multicast and interface-specific transport cases.

### 5. Production hardening is still thin

The driver now works, but it still has a number of hardening gaps:

- hot-path debug prints are still present,
- some error paths still swallow failures,
- the runtime still relies on manual buffer interpretation and alignment-sensitive casts,
- the embedded driver/client lifecycle is more fragile than upstream,
- stress coverage is still light.

## Code Quality Assessment

### Good

- Module boundaries are clean and mostly map to Aeron concepts.
- Tests are in place for many low-level behaviors.
- The release gate is now automated and reproducible.
- The code is readable and intentionally structured rather than monolithic.

### Needs Work

- The code still uses `catch {}` in some driver paths where upstream would preserve and surface richer failure information.
- Several components are still more permissive than ideal for a network-facing driver.
- Some concurrency-sensitive logic is still implemented conservatively or with ad hoc guards rather than a fully hardened state machine.
- The codebase is not yet at the same maturity level as upstream Aeron’s long-lived driver and archive implementations.

## Release Conclusion

This codebase is release-ready for the current v1.0.0 scope if the goal is:

- a Zig driver,
- a Java interoperability proof,
- a stable baseline for the next phase.

It is **not** yet at feature parity with upstream Aeron.

## Recommended Next Stage

Focus the next phase on:

1. transport hardening and protocol breadth,
2. reverse interop,
3. archive parity,
4. cluster parity,
5. stress and failure-mode testing.

