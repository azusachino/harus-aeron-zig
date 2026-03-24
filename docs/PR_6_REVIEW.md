# PR #6 Review: Phase 5b — Fuzz Targets, Benchmarks, and Stress Tests

**Status**: ISSUES FOUND (4 convention violations)

## Summary
PR #6 adds 6 fuzz targets, 3 benchmarks, and 3 stress tests with build.zig and Makefile integration. Total additions: 89 lines to build.zig, 12 lines to Makefile, 14 new test/benchmark files.

---

## Issues Found

### 1. CONVENTION VIOLATION: Stress Tests - Verbose Variable Names (build.zig lines ~157-186)
**Severity**: MEDIUM — Code readability issue

**Problem**: Stress test section replicates the same test creation block 3 times with explicit variables for each test, then manually depends them on the step.

```zig
    // Stress tests
    const stress_term_rotation = b.addTest(.{...});
    const run_stress_term_rotation = b.addRunArtifact(stress_term_rotation);

    const stress_concurrent_pubs = b.addTest(.{...});
    const run_stress_concurrent_pubs = b.addRunArtifact(stress_concurrent_pubs);

    const stress_reconnect = b.addTest(.{...});
    const run_stress_reconnect = b.addRunArtifact(stress_reconnect);

    const stress_step = b.step("stress", "Run stress tests");
    stress_step.dependOn(&run_stress_term_rotation.step);
    stress_step.dependOn(&run_stress_concurrent_pubs.step);
    stress_step.dependOn(&run_stress_reconnect.step);
```

**Convention Mismatch**: The Fuzz tests section (lines ~102-119) uses a **loop over an array** to avoid this repetition:

```zig
    // Fuzz tests
    const fuzz_files = [_][]const u8{...};
    const fuzz_step = b.step("fuzz", "Run fuzz tests");
    for (fuzz_files) |fuzz_file| {
        const fuzz_test = b.addTest(.{...});
        fuzz_step.dependOn(&b.addRunArtifact(fuzz_test).step);
    }
```

**Fix**: Stress tests should use the same loop pattern as fuzz tests:
```zig
    const stress_files = [_][]const u8{
        "test/stress/term_rotation.zig",
        "test/stress/concurrent_pubs.zig",
        "test/stress/reconnect.zig",
    };
    const stress_step = b.step("stress", "Run stress tests");
    for (stress_files) |stress_file| {
        const stress_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(stress_file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "aeron", .module = aeron_mod },
                },
            }),
        });
        stress_step.dependOn(&b.addRunArtifact(stress_test).step);
    }
```

---

### 2. CONVENTION VIOLATION: Benchmarks - Hard-coded `.ReleaseFast` (build.zig lines ~131)
**Severity**: LOW — Inconsistent optimization handling

**Problem**: Benchmarks hardcode `.ReleaseFast` for optimization while fuzz and stress tests use the provided `optimize` parameter.

```zig
    for (bench_files) |bench| {
        const bench_exe = b.addExecutable(.{
            .name = bench.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bench.path),
                .target = target,
                .optimize = .ReleaseFast,  // <-- Hard-coded
                ...
```

**Issue**: This prevents users from running benchmarks with different optimization levels (e.g., `zig build bench -Doptimize=Debug` for debugging). Violates principle of making all build options configurable.

**Better approach**: Use the provided `optimize` parameter consistently:
```zig
                .optimize = optimize,
```

If benchmarks *require* `.ReleaseFast`, this should be documented, but hardcoding limits flexibility and deviates from the pattern used for unit/integration/fuzz/stress tests.

---

### 3. STYLE: Missing Makefile target documentation (Makefile lines ~85-92)
**Severity**: LOW — Documentation inconsistency

**Problem**: The three new Makefile targets lack the `##` documentation comment used throughout the file:

```makefile
# From existing pattern (line 38):
tutorial-check:  ## Compile-check tutorial stubs
	$(NIX_RUN) zig build tutorial-check

# New targets (missing ##):
fuzz:
	$(NIX_RUN) zig build fuzz

bench:
	$(NIX_RUN) zig build bench

stress:
	$(NIX_RUN) zig build stress
```

**Fix**: Add `##` descriptions:
```makefile
fuzz:           ## Run fuzz tests
	$(NIX_RUN) zig build fuzz

bench:          ## Run benchmarks
	$(NIX_RUN) zig build bench

stress:         ## Run stress tests
	$(NIX_RUN) zig build stress
```

---

### 4. POSSIBLE ISSUE: Incomplete Makefile integration for `make check` (Makefile line ~33)
**Severity**: MEDIUM — Potential test coverage gap

**Problem**: The main `check` target still only runs `test`, not the new test categories:

```makefile
check: fmt-check build test
```

**Question**: Should `make check` also run fuzz tests? The PR description says:
- `make fuzz` runs all 6 fuzz targets
- `make bench` builds and runs benchmarks
- `make stress` runs stress tests

But `make check` doesn't invoke any of these. According to `.claude/rules/release.md`:
- "Run `make check` before any release commit"
- "Verify ... before v1.0"

**Current behavior**: A release could be cut without running fuzz/stress/bench validation.

**Recommendation**: Clarify intent:
1. Should `check` include fuzz tests (external input validation)?
2. Should benchmarks/stress tests run in CI or only locally?
3. If they should be in `check`, update: `check: fmt-check build test fuzz`

---

## Summary

| Issue | Type | Location | Severity |
|-------|------|----------|----------|
| Stress tests don't use array loop pattern | Convention mismatch | build.zig ~157-186 | MEDIUM |
| Benchmarks hardcode `.ReleaseFast` | Configuration lock-in | build.zig ~131 | LOW |
| Makefile targets missing `##` docs | Documentation | Makefile ~86-92 | LOW |
| `make check` doesn't run fuzz/stress | Test coverage gap | Makefile ~33 | MEDIUM |

**Recommendation**: Address issues #1, #4 before merging. Issue #2 and #3 are code quality improvements that should be fixed but are less critical.
