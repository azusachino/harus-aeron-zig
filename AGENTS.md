# harus-aeron-zig

Aeron protocol reimplementation in Zig. Wire-compatible with the real Aeron UDP protocol
(https://github.com/aeron-io/aeron). Targets: Media Driver first, then Archive, then Cluster.

## Tech Stack & Architecture

- **Language**: Zig 0.15.2 (nixpkgs unstable)
- **Build**: `zig build` via Makefile
- **Dev tooling**: Nix devShell (`nix develop`)
- **Components**:
  - `src/protocol/` — Aeron wire protocol frame codecs
  - `src/logbuffer/` — Three-term log buffer (mmap-backed)
  - `src/ipc/` — Lock-free ring buffer + broadcast transmitter (client↔driver IPC)
  - `src/transport/` — UDP unicast/multicast channel, poll/select loop
  - `src/driver/` — MediaDriver: Conductor, Sender, Receiver agents
  - `src/publication.zig` / `src/subscription.zig` — Client-side API
  - `src/aeron.zig` — Client library entry point
  - `src/main.zig` — Driver process binary

## Build, Run & Test

Enter dev shell: `nix develop`
Run any tool without entering: `nix develop --command <cmd>`
All daily operations go through `make <target>`:

```bash
make build            # zig build
make build-driver     # build driver binary only
make test             # run all tests (unit + integration)
make test-unit        # unit tests only
make test-integration # integration tests only
make fmt              # zig fmt + prettier
make check            # fmt-check + build + test
make clean            # remove zig-out/ .zig-cache/
make run              # run media driver
```

## Coding Conventions

- **Explicit allocator API everywhere**: `list.append(allocator, item)`, `list.deinit(allocator)` — no implicit GPA
- **Error handling**: use `!T` return types; no `catch unreachable` in production paths
- **No global state**: pass allocator + config down from `main`
- **extern struct for wire types**: all protocol frames use `extern struct` for guaranteed layout
- **comptime size assertions**: `comptime { std.debug.assert(@sizeOf(T) == N); }` for all frame types
- **Naming**: snake_case for variables/functions, PascalCase for types, SCREAMING_SNAKE for constants
- **Tests**: inline `test` blocks per file + integration tests in `test/`

## Key Files & Entry Points

- `src/main.zig` — driver binary entry
- `src/aeron.zig` — client library root
- `src/protocol/frame.zig` — all Aeron wire frame structs
- `src/driver/conductor.zig` — DriverConductor (command/control core)
- `docs/plan.md` — phased implementation roadmap
- `docs/architecture.md` — system architecture

## Tutorial Layer

This repo is also a structured course. Two parallel code trees:

- **`src/`** — full reference implementation (always green, `make check` must pass)
- **`tutorial/`** — learner stubs mirroring `src/`, bodies are `@panic("TODO: implement")`

**Key conventions for agents writing code:**
- Add `// LESSON(chapter-slug): why. See docs/tutorial/part/chapter.md` above every significant struct/function in `src/`
- After implementing a chapter in `src/`, write the stub in `tutorial/` and the chapter doc in `docs/tutorial/`
- Tag `main` as `chapter-NN-slug` after each chapter merges
- Full design: `docs/specs/2026-03-17-tutorial-course-design.md`

## Quality Standards

- `make check` must pass before every commit
- All frame types must have `comptime` size assertions matching the spec
- No `unreachable` in receiver/conductor paths — Aeron receives untrusted UDP
- Unit tests for every codec function; integration tests for pub/sub round-trip
