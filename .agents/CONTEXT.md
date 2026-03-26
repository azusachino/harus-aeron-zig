# Agent Context — harus-aeron-zig

Internal living doc. Always read at session start. Update when architecture or conventions change.

## Agent Rules

### DO

- Use `make <target>` for all task execution — never run `zig` or `prettier` directly
- At session start: load MCP entities via `read_graph()`; load `[harus-aeron-zig]:session`
- At session end: write state to `harus-aeron-zig:session` MCP entity
- Dispatch sub-agents for independent parallel tasks by default
- Update this file when architecture or conventions change
- Use `extern struct` for all wire protocol types — layout must be exact
- Add `comptime { std.debug.assert(@sizeOf(T) == N); }` for every frame type
- Reference https://github.com/aeron-io/aeron source when implementing protocol details

### DON'T

- Commit without user confirmation
- Use `git add -A` or `git add .`
- Install tools globally — all tools come from `flake.nix`
- Use `unreachable` in receive/decode paths — UDP data is untrusted
- Invent protocol details — check the reference implementation first

## Tool Provisioning

- Enter dev shell: `nix develop`
- One-off command: `nix develop --command <cmd>` (or `make <target>` — handles this automatically)
- Never install tools outside the flake — add to `devShells.default.packages` in `flake.nix`
- `make setup-upstream-aeron` creates/refreshes a shallow clone of the official Aeron upstream in `vendor/aeron`
- `make setup-upstream-zig` creates/refreshes a shallow clone of Zig `0.15.2` in `vendor/zig`
- Prefer `vendor/aeron` as the first source of truth for upstream protocol/spec checks when it exists
- Prefer `vendor/zig` as the first source of truth for Zig 0.15.2 API/source checks when it exists
- `build.zig` explicitly links libc for executables/tests because the driver records `getpid()` in `cnc.dat`; do not remove that linkage unless the PID path is redesigned to avoid libc
- Local interop iteration uses a reusable Zig Nix build-env image; warm it with `make setup-interop-base` and reuse it via `ZIG_BUILD_ENV_IMAGE`

## Tutorial Layer

Two parallel code trees — agents must maintain both:

| Tree | Purpose | CI |
|------|---------|-----|
| `src/` | Reference implementation — always compiles and passes tests | `make check` |
| `tutorial/` | Learner stubs — `@panic("TODO: implement")` bodies | `make tutorial-check` (compile only) |

**LESSON comment format** (add to every significant struct/function in `src/`):
```zig
// LESSON(chapter-slug): why this design. See docs/tutorial/part/chapter.md
```

**Chapter workflow for agents**:
1. Implement module in `src/` with LESSON annotations
2. Write stub in `tutorial/` mirroring the same file
3. Write `docs/tutorial/part/chapter.md`
4. Tag: `git tag chapter-NN-slug`

**Full course design**: `docs/specs/2026-03-17-tutorial-course-design.md`

## Project Context

- Wire protocol reference: https://github.com/aeron-io/aeron (C++ driver, Java client)
- Current upstream pin for interop/docs/tests: Aeron `1.50.2`
- Local upstream source checkout should come from `make setup-upstream-aeron` and defaults to `release/1.50.x`
- If `vendor/aeron` is missing or stale, refresh it before using secondary local docs or network lookups
- Local Zig upstream source checkout should come from `make setup-upstream-zig` and defaults to tag `0.15.2`
- If Zig API behavior is unclear, check `vendor/zig` before guessing from memory
- For Agrona shared-memory IPC parity, prefer the vendored C client sources when the Java Agrona sources are not present:
  `vendor/aeron/aeron-client/src/main/c/concurrent/aeron_broadcast_{descriptor,transmitter,receiver}.*`
  and `vendor/aeron/aeron-client/src/test/c/concurrent/aeron_broadcast_*_test.cpp`
- Key C file for UDP protocol: `aeron-driver/src/main/c/protocol/aeron_udp_protocol.h`
- Key Java file for log buffer: `aeron-client/src/main/java/io/aeron/logbuffer/LogBufferDescriptor.java`
- Term buffer: 3 partitions, each a power-of-2 size (default 16MB), memory-mapped
- IPC: client→driver via ManyToOneRingBuffer; driver→client via BroadcastTransmitter
- Frame alignment: all frames padded to 32-byte boundaries (FRAME_ALIGNMENT = 32)
- Session established via SETUP handshake before DATA frames flow

## Phase 5 Additions

### CLI & Tooling (Phase 5c)

- `src/cli.zig` — subcommand dispatcher; parses `[driver|archive|cluster|stat|errors|loss|streams|events|cluster-tool|help]` plus legacy flags (`--archive`, `--cluster`, `--counters`)
- `src/cnc.zig` — CnC file descriptor; maps `/dev/shm/aeron/cnc.dat` for shared-memory stats (placeholder until full mmap)
- `src/tools/{stat,errors,loss,streams,events,cluster_tool}.zig` — one function each, reads CnC descriptor; all placeholder until CnC mmap is implemented
- `examples/{basic_publisher,basic_subscriber,throughput}.zig` — reference client apps; built via `make build` / `zig build examples`

### Infrastructure Layer (Phase 5d)

- `src/log.zig` — structured logging (JSON or text); level filtered by `AERON_LOG_LEVEL` env var; wraps `std.log`
- `src/config.zig` — reads env vars (`AERON_DIR`, `AERON_TERM_BUFFER_LENGTH`, `AERON_HEALTH_PORT`, etc.) with platform-aware defaults; `Config.validate()` must be called at startup
- `src/signal.zig` — installs SIGTERM/SIGINT handlers; exposes `signal.isRunning()` atomic flag for graceful shutdown loops
- `src/health.zig` — HTTP server on `AERON_HEALTH_PORT` (default 8080) serving `/healthz` (always 200) and `/readyz` (200 when ready flag set); must be started in `main.zig` and loop must check `signal.isRunning()`

## Current Parity State

- **Phase 8+9 complete (2026-03-25)** — all tasks done; `make check` is green; tutorial 31/31 chapters.
- Wire protocol gaps closed: remaining frame variants, strict URI parsing, malformed-input rejection.
- Driver liveness and cleanup hardened: image/publication lifecycle, flow-control under reorder/gap, conductor/sender/receiver resource teardown.
- Archive operational: segment rotation across multiple persisted segments, catalog descriptor fidelity, restart reconstruction.
- Cluster consensus fidelity: follower catch-up/rejoin, restart/election/commit continuity, session redirect and failover.
- CnC tooling real: `stat`, `errors`, `loss`, `streams`, `events`, `cluster-tool` backed by actual mmap reads and counters.
- Interop automated: local Zig↔Java smoke/full runs use `deploy/docker-compose.ci.yml` with `make interop` / `make interop-smoke`; prefer Colima + Docker client on macOS and Podman on Linux.
- `make interop-smoke` uses the finite Java helper in `deploy/InteropSmoke.java` so the smoke target exits on a successful Java `addSubscription` / close cycle against the Zig driver instead of hanging on an endless sample.
- **Known parity gaps**: IPC 95% (multi-destination, advanced keepalive), Cluster 90% (snapshot coordination, member discovery), URI 95% (media type extensions). See `.agents/PARITY_AUDIT.md`.
- Performance baseline established: `src/bench/` (throughput/latency/fanout) + `test/stress/` soak scenarios for reconnect, archive replay, cluster failover.
- Roadmap for next work lives in `docs/plan.md`; no active stale investigations.
