# CLAUDE.md

## Project

Aeron protocol reimplementation in Zig — wire-compatible UDP transport, media driver, archive, and cluster.
Reference: https://github.com/aeron-io/aeron

## Commands

```bash
make fmt              # Format all files
make lint             # fmt-check
make check            # fmt-check + build + test
make test             # Run all tests
make test-unit        # Unit tests only
make test-integration # Integration tests
make build            # zig build
make run              # Run media driver
make clean            # Remove build artifacts
```

## Rules

- See `.claude/rules/core.md` for agent DO/DON'T rules
- See `.claude/rules/release.md` for release process rules

## Key Files

- `src/main.zig` — driver binary entry
- `src/aeron.zig` — client library root
- `src/protocol/frame.zig` — Aeron wire frame structs
- `src/driver/conductor.zig` — DriverConductor (core command/control)
- `docs/plan.md` — phased implementation roadmap with all tasks
- `docs/architecture.md` — full system architecture
