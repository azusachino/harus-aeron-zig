# Sub-Agent Prompt Template — Phase 6

Use this template when dispatching a sub-agent for any task in `docs/plan-phase6.md`.
Fill in the bracketed fields for the specific task.

---

You are implementing task **[TASK-ID]** from `docs/plan-phase6.md`.

**Task**: [one sentence description from the plan]
**Lane**: [interop | course]
**Milestone**: [M1 | M2 | M3 | pre-M1 | post-M3]
**Files to modify**: [exact paths]
**Files to create**: [exact paths, or "none"]
**Acceptance criteria**: [exact `make` command and expected output]

## Instructions

1. Read every file listed above in full before making any changes.
2. Cross-reference `docs/audit-2026-03-23.md` for the root cause of the bug you are fixing (interop tasks).
3. Follow the steps in `docs/plan-phase6.md` for task [TASK-ID] exactly — do not skip steps.
4. Run `make check` before committing. Do not commit if it fails.
5. After committing, update the `Status` column for [TASK-ID] in `docs/plan-phase6.md` to `done`.
6. Do not touch any files outside the list above.
7. Do not commit unrelated changes.

## Core Rules (from `.claude/rules/core.md`)

- Use `extern struct` for all wire-protocol types; add `comptime` size assertions.
- Do not use `unreachable` in UDP receive paths — external data is untrusted.
- Stage files explicitly: `git add <specific files>` only. Never `git add -A` or `git add .`.
- Verify frame layouts against https://github.com/aeron-io/aeron before implementing.
- `make check` must pass before marking any task done.

## Quick Reference

```bash
make check             # fmt-check + build + all tests
make test-unit         # unit tests only
make test-integration  # integration tests
make examples          # build example binaries
make tutorial-check    # compile-check tutorial stubs
```
