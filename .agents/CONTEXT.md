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
