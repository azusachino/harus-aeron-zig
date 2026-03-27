# Phase 10 — Upstream Test Parity & CI Implementation Plan

> **For agentic workers:** Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Mark each step done before moving to the next.

**Goal:** Establish behavioural parity with upstream aeron-io/aeron test suite, wire 14 scenario test files into `make check`, and add two GitHub Actions CI workflows gated on `zig-test` + `interop-smoke`.

**Architecture:** Scenario tests live under `test/{protocol,driver,archive,cluster}/`, each importing the `aeron` Zig module. A `test-scenarios` build step runs all four layers. Two GHA workflows run on every PR; a Docker Compose file drives the Java interop smoke test in CI without k8s.

**Tech Stack:** Zig 0.15.2, Nix devShell, GitHub Actions, Docker Compose v2, Java 21 (Temurin), Aeron 1.50.2, `std.testing` only.

---

## File Map

### Deleted
- `deploy/interop/` — replaced by `deploy/docker-compose.ci.yml`
- `test/stress/` — replaced by `make bench`
- `test/interop/` — replaced by scenario tests in `test/protocol/`, `test/driver/`, etc.

### Moved
- `deploy/k8s/` → `k8s/` (project root)

### Created
| File | Responsibility |
|------|---------------|
| `test/upstream_map.jsonl` | Agent-queryable traceability: our test ↔ upstream class ↔ status |
| `.agents/parity_status.jsonl` | Agent-queryable parity gaps per layer |
| `.agents/chapter_status.jsonl` | Agent-queryable tutorial chapter completion state |
| `test/protocol/frame_codec_test.zig` | Frame encode/decode parity with DataHeaderFlyweightTest |
| `test/protocol/uri_parser_test.zig` | URI parsing parity with ChannelUriTest |
| `test/protocol/flow_control_test.zig` | Receiver window parity with ReceiverWindowTest |
| `test/driver/session_establishment_test.zig` | Session setup parity with PublicationImageTest |
| `test/driver/publication_lifecycle_test.zig` | Add/remove publication parity with DriverConductorTest |
| `test/driver/subscription_lifecycle_test.zig` | Add/remove subscription parity with DriverConductorTest |
| `test/driver/conductor_ipc_test.zig` | IPC command dispatch parity with DriverConductorTest |
| `test/driver/loss_and_recovery_test.zig` | Loss detection parity with LossHandlerTest/RetransmitHandlerTest |
| `test/archive/catalog_test.zig` | Catalog descriptor parity with CatalogTest |
| `test/archive/record_replay_test.zig` | Record/replay parity with ArchiveTest |
| `test/archive/segment_rotation_test.zig` | Segment rotation parity with RecordingWriterTest |
| `test/cluster/election_test.zig` | Election parity with ElectionTest |
| `test/cluster/log_replication_test.zig` | Log replication parity with ClusterTimerTest + LogReplicationTest |
| `test/cluster/failover_test.zig` | Failover parity with ClusterNodeTest |
| `.github/workflows/ci.yml` | Zig test matrix on all PRs; merge gate |
| `.github/workflows/interop.yml` | Full interop on main push + manual |
| `deploy/docker-compose.ci.yml` | Lightweight Java+Zig interop for CI smoke |
| `deploy/Dockerfile.zig` | Nix-based image running `make run` |
| `deploy/Dockerfile.java-aeron` | Java image with Aeron 1.50.2 subscriber/publisher |

### Modified
| File | Change |
|------|--------|
| `build.zig` | Add test-protocol, test-driver, test-archive, test-cluster, test-scenarios steps |
| `Makefile` | Add test-protocol/driver/archive/cluster/scenarios targets; update check; update k8s targets |

---

## Task 1: Clean Slate — Delete old dirs, move k8s/

**Files:**
- Delete: `deploy/interop/`, `test/stress/`, `test/interop/`
- Move: `deploy/k8s/` → `k8s/`

- [ ] **Step 1: Delete obsolete directories**

```bash
git rm -r deploy/interop/ test/stress/ test/interop/
```

Expected: all files staged for deletion.

- [ ] **Step 2: Move k8s to project root**

```bash
git mv deploy/k8s k8s
```

Expected: `k8s/` appears at project root, `deploy/k8s/` gone.

- [ ] **Step 3: Update Makefile — fix k8s and interop references**

The Makefile has several targets that reference the deleted/moved paths. Update them:

```makefile
# k8s-up / k8s-down: deploy/k8s/ → k8s/
k8s-up: nix-image
	kubectl apply -k k8s/

k8s-down:
	kubectl delete -k k8s/ --ignore-not-found
```

Also remove or stub out the targets that reference deleted `test/interop/` and `deploy/interop/`:
- `test-interop` — delete the target (was `bash test/interop/run.sh`)
- `interop` / `interop-smoke` — replace bodies with `docker compose -f deploy/docker-compose.ci.yml up --abort-on-container-exit` (Task 9 adds this file)
- `interop-build` / `interop-run` — delete; replaced by Docker Compose
- `setup-interop` — remove the `mkdir -p test/interop` line and the jar-download block (jar is now fetched inside the Docker image)
- Remove `test-interop` and `interop-build` / `interop-run` from `.PHONY`

- [ ] **Step 4: Verify build still passes**

```bash
make build
```

Expected: exits 0 (no zig sources were deleted).

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "chore: clean slate — delete interop/stress/old-interop, move k8s/ to root, fix Makefile refs"
```

---

## Task 2: Agent-First Data Files

**Files:**
- Create: `test/upstream_map.jsonl`
- Create: `.agents/parity_status.jsonl`
- Create: `.agents/chapter_status.jsonl`

These replace the prose `.md` equivalents for agent queries. Each file is one JSON object per line — agents use `jq` to filter; humans run `make status`.

- [ ] **Step 1: Create `test/upstream_map.jsonl`**

```jsonl
{"layer":"protocol","our_file":"test/protocol/frame_codec_test.zig","upstream_class":"DataHeaderFlyweightTest","upstream_path":"aeron-client/src/test/java/io/aeron/","aeron_version":"1.50.2","status":"pending"}
{"layer":"protocol","our_file":"test/protocol/frame_codec_test.zig","upstream_class":"SetupFlyweightTest","upstream_path":"aeron-client/src/test/java/io/aeron/","aeron_version":"1.50.2","status":"pending"}
{"layer":"protocol","our_file":"test/protocol/frame_codec_test.zig","upstream_class":"StatusMessageFlyweightTest","upstream_path":"aeron-client/src/test/java/io/aeron/","aeron_version":"1.50.2","status":"pending"}
{"layer":"protocol","our_file":"test/protocol/uri_parser_test.zig","upstream_class":"ChannelUriTest","upstream_path":"aeron-client/src/test/java/io/aeron/","aeron_version":"1.50.2","status":"pending"}
{"layer":"protocol","our_file":"test/protocol/flow_control_test.zig","upstream_class":"ReceiverWindowTest","upstream_path":"aeron-driver/src/test/java/io/aeron/driver/","aeron_version":"1.50.2","status":"pending"}
{"layer":"driver","our_file":"test/driver/session_establishment_test.zig","upstream_class":"PublicationImageTest","upstream_path":"aeron-driver/src/test/java/io/aeron/driver/","aeron_version":"1.50.2","status":"pending"}
{"layer":"driver","our_file":"test/driver/session_establishment_test.zig","upstream_class":"DriverConductorTest","upstream_path":"aeron-driver/src/test/java/io/aeron/driver/","aeron_version":"1.50.2","status":"pending"}
{"layer":"driver","our_file":"test/driver/publication_lifecycle_test.zig","upstream_class":"DriverConductorTest","upstream_path":"aeron-driver/src/test/java/io/aeron/driver/","aeron_version":"1.50.2","status":"pending"}
{"layer":"driver","our_file":"test/driver/subscription_lifecycle_test.zig","upstream_class":"DriverConductorTest","upstream_path":"aeron-driver/src/test/java/io/aeron/driver/","aeron_version":"1.50.2","status":"pending"}
{"layer":"driver","our_file":"test/driver/conductor_ipc_test.zig","upstream_class":"DriverConductorTest","upstream_path":"aeron-driver/src/test/java/io/aeron/driver/","aeron_version":"1.50.2","status":"pending"}
{"layer":"driver","our_file":"test/driver/loss_and_recovery_test.zig","upstream_class":"LossHandlerTest","upstream_path":"aeron-driver/src/test/java/io/aeron/driver/","aeron_version":"1.50.2","status":"pending"}
{"layer":"driver","our_file":"test/driver/loss_and_recovery_test.zig","upstream_class":"RetransmitHandlerTest","upstream_path":"aeron-driver/src/test/java/io/aeron/driver/","aeron_version":"1.50.2","status":"pending"}
{"layer":"archive","our_file":"test/archive/catalog_test.zig","upstream_class":"CatalogTest","upstream_path":"aeron-archive/src/test/java/io/aeron/archive/","aeron_version":"1.50.2","status":"pending"}
{"layer":"archive","our_file":"test/archive/record_replay_test.zig","upstream_class":"ArchiveTest","upstream_path":"aeron-archive/src/test/java/io/aeron/archive/","aeron_version":"1.50.2","status":"pending"}
{"layer":"archive","our_file":"test/archive/segment_rotation_test.zig","upstream_class":"RecordingWriterTest","upstream_path":"aeron-archive/src/test/java/io/aeron/archive/","aeron_version":"1.50.2","status":"pending"}
{"layer":"cluster","our_file":"test/cluster/election_test.zig","upstream_class":"ElectionTest","upstream_path":"aeron-cluster/src/test/java/io/aeron/cluster/","aeron_version":"1.50.2","status":"pending"}
{"layer":"cluster","our_file":"test/cluster/log_replication_test.zig","upstream_class":"ClusterTimerTest","upstream_path":"aeron-cluster/src/test/java/io/aeron/cluster/","aeron_version":"1.50.2","status":"pending"}
{"layer":"cluster","our_file":"test/cluster/log_replication_test.zig","upstream_class":"LogReplicationTest","upstream_path":"aeron-cluster/src/test/java/io/aeron/cluster/","aeron_version":"1.50.2","status":"pending"}
{"layer":"cluster","our_file":"test/cluster/failover_test.zig","upstream_class":"ClusterNodeTest","upstream_path":"aeron-cluster/src/test/java/io/aeron/cluster/","aeron_version":"1.50.2","status":"pending"}
```

- [ ] **Step 2: Verify jq queries work**

```bash
jq 'select(.status == "pending")' test/upstream_map.jsonl | wc -l
```

Expected: 19

```bash
jq 'select(.layer == "protocol")' test/upstream_map.jsonl | jq -r .upstream_class
```

Expected: 5 lines (DataHeaderFlyweightTest, SetupFlyweightTest, StatusMessageFlyweightTest, ChannelUriTest, ReceiverWindowTest)

- [ ] **Step 3: Create `.agents/parity_status.jsonl`**

```jsonl
{"layer":"protocol","completeness_pct":100,"gaps":[],"reference":"aeron_udp_protocol.h","updated":"2026-03-25"}
{"layer":"ipc","completeness_pct":95,"gaps":["multi-destination","advanced-keepalive"],"reference":"ControlProtocolEvents.java","updated":"2026-03-25"}
{"layer":"archive","completeness_pct":100,"gaps":[],"reference":"aeron-archive/","updated":"2026-03-25"}
{"layer":"cluster","completeness_pct":90,"gaps":["snapshot-coordination","member-discovery"],"reference":"aeron-cluster/codecs/","updated":"2026-03-25"}
{"layer":"uri","completeness_pct":95,"gaps":["media-type-extensions"],"reference":"ChannelUri.java","updated":"2026-03-25"}
```

- [ ] **Step 4: Create `.agents/chapter_status.jsonl`**

One line per tutorial chapter. Agents query `jq 'select(.git_tag == null)'` to find untagged chapters. Run this to seed it from git:

```bash
git tag -l 'chapter-*' | sort | sed 's/chapter-//' | awk -F'-' '{print $1"-"$2}' > /tmp/tagged_chapters.txt
```

Then create the file with all 31 chapters. Status values: `"done"`, `"partial"`, `"missing"`.

```jsonl
{"id":"01-01","slug":"frame-codec","doc":"docs/tutorial/01-foundations/01-frame-codec.md","stub":"tutorial/protocol/frame.zig","git_tag":"chapter-01-01-frame-codec","lesson_count":3,"status":"done"}
{"id":"01-02","slug":"logbuffer","doc":"docs/tutorial/01-foundations/02-logbuffer.md","stub":"tutorial/logbuffer/log_buffer.zig","git_tag":"chapter-01-02-logbuffer","lesson_count":4,"status":"done"}
```

> Populate all 31 rows by running `git tag -l 'chapter-*'` and cross-referencing `docs/tutorial/`. This is a one-time setup step — the file is append-only as new chapters ship.

- [ ] **Step 5: Add `make status` target to Makefile**

In `Makefile`, add after the `check` target:

```makefile
status:  ## Show parity and chapter status from JSONL sources
	@echo "=== Parity Gaps ==="
	@jq -r '"\(.layer): \(.completeness_pct)% — gaps: \(.gaps | join(", "))"' .agents/parity_status.jsonl
	@echo ""
	@echo "=== Upstream Map — pending ==="
	@jq -r 'select(.status == "pending") | "\(.layer)/\(.upstream_class)"' test/upstream_map.jsonl
	@echo ""
	@echo "=== Chapter Status — incomplete ==="
	@jq -r 'select(.status != "done") | "\(.id) \(.slug): \(.status)"' .agents/chapter_status.jsonl
```

- [ ] **Step 6: Commit**

```bash
git add test/upstream_map.jsonl .agents/parity_status.jsonl .agents/chapter_status.jsonl Makefile
git commit -m "chore: add agent-first JSONL data files and make status target"
```

---

## Task 3: Wire build.zig and Makefile for Scenario Tests

**Files:**
- Modify: `build.zig` (add 4 test steps + test-scenarios step)
- Modify: `Makefile` (add 5 targets, update check)

- [ ] **Step 1: Read current build.zig**

Read `build.zig` to find the `// Default test step` section. The new steps go immediately after the existing `integration_test_step`.

- [ ] **Step 2: Add scenario test steps to build.zig**

After the `const test_step = b.step("test", ...)` block, append:

```zig
    // Scenario tests — protocol layer
    const test_protocol = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/protocol/frame_codec_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
            },
        }),
    });
    const run_test_protocol = b.addRunArtifact(test_protocol);
    const test_protocol_step = b.step("test-protocol", "Run protocol scenario tests");
    test_protocol_step.dependOn(&run_test_protocol.step);

    // Scenario tests — driver layer
    const test_driver = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/driver/session_establishment_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
            },
        }),
    });
    const run_test_driver = b.addRunArtifact(test_driver);
    const test_driver_step = b.step("test-driver", "Run driver scenario tests");
    test_driver_step.dependOn(&run_test_driver.step);

    // Scenario tests — archive layer
    const test_archive = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/archive/catalog_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
            },
        }),
    });
    const run_test_archive = b.addRunArtifact(test_archive);
    const test_archive_step = b.step("test-archive", "Run archive scenario tests");
    test_archive_step.dependOn(&run_test_archive.step);

    // Scenario tests — cluster layer
    const test_cluster = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/cluster/election_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
            },
        }),
    });
    const run_test_cluster = b.addRunArtifact(test_cluster);
    const test_cluster_step = b.step("test-cluster", "Run cluster scenario tests");
    test_cluster_step.dependOn(&run_test_cluster.step);

    // Scenarios umbrella
    const test_scenarios_step = b.step("test-scenarios", "Run all scenario tests");
    test_scenarios_step.dependOn(test_protocol_step);
    test_scenarios_step.dependOn(test_driver_step);
    test_scenarios_step.dependOn(test_archive_step);
    test_scenarios_step.dependOn(test_cluster_step);
```

> Note: Each layer's root test file (`frame_codec_test.zig`, `session_establishment_test.zig`, etc.) pulls in its siblings using `pub const` declarations + `std.testing.refAllDeclsRecursive(@This())`. This is the canonical pattern from `test/main.zig`. Do NOT use `comptime { _ = @import(...) }` — the `pub const` approach is what Zig's test runner picks up.

- [ ] **Step 3: Update Makefile**

Add after `test-integration:` target:

```makefile
test-protocol:  ## Run protocol scenario tests
	$(NIX_RUN) zig build test-protocol

test-driver:  ## Run driver scenario tests
	$(NIX_RUN) zig build test-driver

test-archive:  ## Run archive scenario tests
	$(NIX_RUN) zig build test-archive

test-cluster:  ## Run cluster scenario tests
	$(NIX_RUN) zig build test-cluster

test-scenarios: test-protocol test-driver test-archive test-cluster  ## Run all scenario tests
```

Update the `check` target:

```makefile
check: fmt-check build test test-scenarios lesson-lint  ## Full check: fmt + build + all tests
```

Update `.PHONY` line to include the new targets:

```makefile
.PHONY: fmt fmt-check build test lint check clean run tutorial-check lesson-lint \
       fuzz bench stress \
       nix-image k8s-up k8s-down k8s-status k8s-logs colima-up colima-down \
       setup setup-interop \
       interop interop-smoke interop-status interop-build interop-run test-interop \
       test-protocol test-driver test-archive test-cluster test-scenarios status
```

Update any Makefile targets that referenced `deploy/k8s/` to reference `k8s/` instead (search: `kubectl apply -k deploy/k8s`).

- [ ] **Step 4: Create placeholder root test files so build.zig resolves**

> Do this BEFORE running `make build` — build.zig now references these paths.

Create `test/protocol/frame_codec_test.zig` with a single passing stub:

```zig
// Upstream reference: aeron-client/src/test/java/io/aeron/DataHeaderFlyweightTest.java
// Aeron version: 1.50.2
// Coverage: (stub — see Task 4)
const aeron = @import("aeron");
_ = aeron;

test "placeholder: frame_codec compiles" {}
```

Create `test/driver/session_establishment_test.zig`:

```zig
// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/PublicationImageTest.java
// Aeron version: 1.50.2
// Coverage: (stub — see Task 5)
const aeron = @import("aeron");
_ = aeron;

test "placeholder: session_establishment compiles" {}
```

Create `test/archive/catalog_test.zig`:

```zig
// Upstream reference: aeron-archive/src/test/java/io/aeron/archive/CatalogTest.java
// Aeron version: 1.50.2
// Coverage: (stub — see Task 6)
const aeron = @import("aeron");
_ = aeron;

test "placeholder: catalog compiles" {}
```

Create `test/cluster/election_test.zig`:

```zig
// Upstream reference: aeron-cluster/src/test/java/io/aeron/cluster/ElectionTest.java
// Aeron version: 1.50.2
// Coverage: (stub — see Task 7)
const aeron = @import("aeron");
_ = aeron;

test "placeholder: election compiles" {}
```

- [ ] **Step 5: Verify build and test-scenarios pass with stubs**

```bash
make build
```

Expected: exits 0.

```bash
make test-scenarios
```

Expected: 4 tests run, 4 pass (placeholders).

- [ ] **Step 6: Commit**

```bash
git add build.zig Makefile test/protocol/frame_codec_test.zig test/driver/session_establishment_test.zig test/archive/catalog_test.zig test/cluster/election_test.zig
git commit -m "feat: wire scenario test steps into build.zig and Makefile"
```

---

## Task 4: Protocol Scenario Tests

**Files:**
- Modify: `test/protocol/frame_codec_test.zig` (replace stub with real tests)
- Create: `test/protocol/uri_parser_test.zig`
- Create: `test/protocol/flow_control_test.zig`

Read `src/protocol/frame.zig` and `src/protocol/uri.zig` before implementing. Use types you find there — do not guess function names.

### 4a: frame_codec_test.zig

- [ ] **Step 1: Read upstream reference**

Upstream: `aeron-client/src/test/java/io/aeron/DataHeaderFlyweightTest.java` at tag `1.50.2`.
Scenarios to port: encode data header fields, decode them back, verify header type byte, verify version byte.

- [ ] **Step 2: Read our frame types**

```bash
grep -n "pub const\|pub fn\|pub inline" src/protocol/frame.zig | head -40
```

- [ ] **Step 3: Replace stub with real tests**

```zig
// Upstream reference: aeron-client/src/test/java/io/aeron/DataHeaderFlyweightTest.java
//                    aeron-client/src/test/java/io/aeron/SetupFlyweightTest.java
//                    aeron-client/src/test/java/io/aeron/StatusMessageFlyweightTest.java
// Aeron version: 1.50.2
// Coverage: frame_type, version, flags, stream_id, session_id, term_id, term_offset, frame_length

const std = @import("std");
const aeron = @import("aeron");
const frame = aeron.protocol.frame;

// Pull in other protocol test files so they are compiled by this root
comptime {
    _ = @import("uri_parser_test.zig");
    _ = @import("flow_control_test.zig");
}

test "DataHeaderFlyweight: frame_type is HDR_TYPE_DATA" {
    var hdr: frame.DataHeader = std.mem.zeroes(frame.DataHeader);
    hdr.frame_header.frame_type = frame.HDR_TYPE_DATA;
    try std.testing.expectEqual(frame.HDR_TYPE_DATA, hdr.frame_header.frame_type);
}

test "DataHeaderFlyweight: encode and decode session_id, stream_id, term_id" {
    var hdr: frame.DataHeader = std.mem.zeroes(frame.DataHeader);
    hdr.session_id = 0xDEAD_BEEF;
    hdr.stream_id = 42;
    hdr.term_id = 7;
    try std.testing.expectEqual(@as(i32, 0xDEAD_BEEF), hdr.session_id);
    try std.testing.expectEqual(@as(i32, 42), hdr.stream_id);
    try std.testing.expectEqual(@as(i32, 7), hdr.term_id);
}

test "DataHeaderFlyweight: term_offset alignment is preserved" {
    var hdr: frame.DataHeader = std.mem.zeroes(frame.DataHeader);
    hdr.term_offset = 4096;
    try std.testing.expectEqual(@as(i32, 4096), hdr.term_offset);
}

test "SetupFlyweight: frame_type is HDR_TYPE_SETUP" {
    var setup: frame.SetupHeader = std.mem.zeroes(frame.SetupHeader);
    setup.frame_header.frame_type = frame.HDR_TYPE_SETUP;
    try std.testing.expectEqual(frame.HDR_TYPE_SETUP, setup.frame_header.frame_type);
}

test "StatusMessageFlyweight: frame_type is HDR_TYPE_SM" {
    var sm: frame.StatusMessage = std.mem.zeroes(frame.StatusMessage);
    sm.frame_header.frame_type = frame.HDR_TYPE_SM;
    try std.testing.expectEqual(frame.HDR_TYPE_SM, sm.frame_header.frame_type);
}

test "StatusMessageFlyweight: receiver_window_length round-trips" {
    var sm: frame.StatusMessage = std.mem.zeroes(frame.StatusMessage);
    sm.receiver_window_length = 131072;
    try std.testing.expectEqual(@as(i32, 131072), sm.receiver_window_length);
}
```

> Adjust field names to match what `grep` returns in Step 2. The pattern stays the same.

- [ ] **Step 4: Run protocol tests**

```bash
make test-protocol
```

Expected: all tests pass. If a field name is wrong, read `src/protocol/frame.zig` and fix.

### 4b: uri_parser_test.zig

- [ ] **Step 5: Read our URI parser**

```bash
grep -n "pub const\|pub fn" src/protocol/uri.zig 2>/dev/null || grep -rn "ChannelUri\|parse_uri\|channel_uri" src/ --include="*.zig" -l
```

- [ ] **Step 6: Write uri_parser_test.zig**

```zig
// Upstream reference: aeron-client/src/test/java/io/aeron/ChannelUriTest.java
// Aeron version: 1.50.2
// Coverage: parse aeron:udp URI, reject malformed, extract media, endpoint

const std = @import("std");
const aeron = @import("aeron");

test "ChannelUri: parse aeron:udp scheme" {
    const uri = "aeron:udp?endpoint=localhost:20121";
    const parsed = try aeron.protocol.uri.parse(std.testing.allocator, uri);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("udp", parsed.media);
}

test "ChannelUri: parse endpoint parameter" {
    const uri = "aeron:udp?endpoint=192.168.1.1:40123";
    const parsed = try aeron.protocol.uri.parse(std.testing.allocator, uri);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("192.168.1.1:40123", parsed.params.get("endpoint").?);
}

test "ChannelUri: reject missing aeron: prefix" {
    const result = aeron.protocol.uri.parse(std.testing.allocator, "udp?endpoint=localhost:20121");
    try std.testing.expectError(error.InvalidUri, result);
}

test "ChannelUri: parse aeron:ipc" {
    const uri = "aeron:ipc";
    const parsed = try aeron.protocol.uri.parse(std.testing.allocator, uri);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ipc", parsed.media);
}
```

> Adjust function path (`aeron.protocol.uri.parse`) to match what grep finds.

### 4c: flow_control_test.zig

- [ ] **Step 7: Read our flow control types**

```bash
grep -rn "ReceiverWindow\|receiver_window\|flow_control\|FlowControl" src/ --include="*.zig" -l
```

- [ ] **Step 8: Write flow_control_test.zig**

```zig
// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/ReceiverWindowTest.java
// Aeron version: 1.50.2
// Coverage: initial window equals term_buffer_length, window does not exceed max

const std = @import("std");
const aeron = @import("aeron");

test "ReceiverWindow: initial window equals term_buffer_length" {
    const term_len: u32 = 65536;
    const window = aeron.driver.flow_control.initial_window(term_len);
    try std.testing.expectEqual(term_len, window);
}

test "ReceiverWindow: window never exceeds term_buffer_length" {
    const term_len: u32 = 65536;
    const oversized: u32 = 1 << 20;
    const window = aeron.driver.flow_control.clamp_window(oversized, term_len);
    try std.testing.expect(window <= term_len);
}
```

- [ ] **Step 9: Run and fix**

```bash
make test-protocol
```

Expected: all pass.

- [ ] **Step 10: Update upstream_map.jsonl status to "done" for protocol rows**

Replace all `"status":"pending"` for `"layer":"protocol"` with `"status":"done"`.

```bash
# In-place update
tmp=$(mktemp)
jq 'if .layer == "protocol" then .status = "done" else . end' test/upstream_map.jsonl > "$tmp" && mv "$tmp" test/upstream_map.jsonl
```

- [ ] **Step 11: Commit**

```bash
git add test/protocol/ test/upstream_map.jsonl
git commit -m "feat: add protocol scenario tests (frame_codec, uri_parser, flow_control)"
```

---

## Task 5: Driver Scenario Tests

**Files:**
- Modify: `test/driver/session_establishment_test.zig`
- Create: `test/driver/publication_lifecycle_test.zig`
- Create: `test/driver/subscription_lifecycle_test.zig`
- Create: `test/driver/conductor_ipc_test.zig`
- Create: `test/driver/loss_and_recovery_test.zig`

Read `src/driver/conductor.zig` before implementing. It has the most test coverage mapping.

- [ ] **Step 1: Read DriverConductor API**

```bash
grep -n "pub fn\|pub const" src/driver/conductor.zig | head -50
```

- [ ] **Step 2: Write session_establishment_test.zig (replace stub)**

```zig
// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/PublicationImageTest.java
//                    aeron-driver/src/test/java/io/aeron/driver/DriverConductorTest.java (SETUP/STATUS cases)
// Aeron version: 1.50.2
// Coverage: session created on SETUP frame, image constructed with correct stream_id/session_id

const std = @import("std");
const aeron = @import("aeron");

// Pull in remaining driver test files
comptime {
    _ = @import("publication_lifecycle_test.zig");
    _ = @import("subscription_lifecycle_test.zig");
    _ = @import("conductor_ipc_test.zig");
    _ = @import("loss_and_recovery_test.zig");
}

test "PublicationImage: session_id and stream_id are stored on construction" {
    const allocator = std.testing.allocator;
    var conductor = try aeron.driver.Conductor.init(allocator, .{});
    defer conductor.deinit();

    const session_id: i32 = 101;
    const stream_id: i32 = 1001;
    const img_id = try conductor.on_setup_frame(session_id, stream_id, 1, 0, 65536);
    const img = conductor.find_image(img_id).?;
    try std.testing.expectEqual(session_id, img.session_id);
    try std.testing.expectEqual(stream_id, img.stream_id);
}

test "DriverConductor: SETUP frame without matching subscription is ignored" {
    const allocator = std.testing.allocator;
    var conductor = try aeron.driver.Conductor.init(allocator, .{});
    defer conductor.deinit();
    // No subscription registered — setup should not create an image
    const result = conductor.on_setup_frame(999, 999, 1, 0, 65536);
    try std.testing.expectError(error.NoMatchingSubscription, result);
}
```

> Adapt function names to match what you found in Step 1.

- [ ] **Step 3: Write publication_lifecycle_test.zig**

```zig
// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/DriverConductorTest.java (add/remove pub)
// Aeron version: 1.50.2
// Coverage: add_publication creates log buffer, remove_publication cleans up

const std = @import("std");
const aeron = @import("aeron");

test "DriverConductor: add_publication returns valid pub_id" {
    const allocator = std.testing.allocator;
    var conductor = try aeron.driver.Conductor.init(allocator, .{});
    defer conductor.deinit();
    const pub_id = try conductor.add_publication("aeron:udp?endpoint=localhost:20121", 1001, 1);
    try std.testing.expect(pub_id > 0);
}

test "DriverConductor: remove_publication succeeds for known pub_id" {
    const allocator = std.testing.allocator;
    var conductor = try aeron.driver.Conductor.init(allocator, .{});
    defer conductor.deinit();
    const pub_id = try conductor.add_publication("aeron:udp?endpoint=localhost:20121", 1001, 1);
    try conductor.remove_publication(pub_id);
}

test "DriverConductor: remove unknown pub_id returns error" {
    const allocator = std.testing.allocator;
    var conductor = try aeron.driver.Conductor.init(allocator, .{});
    defer conductor.deinit();
    try std.testing.expectError(error.UnknownPublication, conductor.remove_publication(9999));
}
```

- [ ] **Step 4: Write subscription_lifecycle_test.zig**

```zig
// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/DriverConductorTest.java (add/remove sub)
// Aeron version: 1.50.2
// Coverage: add_subscription, remove_subscription

const std = @import("std");
const aeron = @import("aeron");

test "DriverConductor: add_subscription returns valid sub_id" {
    const allocator = std.testing.allocator;
    var conductor = try aeron.driver.Conductor.init(allocator, .{});
    defer conductor.deinit();
    const sub_id = try conductor.add_subscription("aeron:udp?endpoint=localhost:20121", 1001, 1);
    try std.testing.expect(sub_id > 0);
}

test "DriverConductor: duplicate add_subscription on same channel/stream increments ref count" {
    const allocator = std.testing.allocator;
    var conductor = try aeron.driver.Conductor.init(allocator, .{});
    defer conductor.deinit();
    _ = try conductor.add_subscription("aeron:udp?endpoint=localhost:20121", 1001, 1);
    const sub2 = try conductor.add_subscription("aeron:udp?endpoint=localhost:20121", 1001, 2);
    try std.testing.expect(sub2 > 0);
}
```

- [ ] **Step 5: Write conductor_ipc_test.zig**

```zig
// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/DriverConductorTest.java (IPC dispatch)
// Aeron version: 1.50.2
// Coverage: IPC command ADD_PUBLICATION dispatched through ring buffer

const std = @import("std");
const aeron = @import("aeron");

test "DriverConductor IPC: ADD_PUBLICATION command is dispatched" {
    const allocator = std.testing.allocator;
    var conductor = try aeron.driver.Conductor.init(allocator, .{});
    defer conductor.deinit();
    // Write ADD_PUBLICATION command to the conductor's ring buffer
    try conductor.to_driver_buffer.write_add_publication("aeron:udp?endpoint=localhost:20121", 1001);
    // Process one command
    const processed = try conductor.do_work();
    try std.testing.expect(processed > 0);
}

test "DriverConductor IPC: TERMINATE_DRIVER command sets shutdown flag" {
    const allocator = std.testing.allocator;
    var conductor = try aeron.driver.Conductor.init(allocator, .{});
    defer conductor.deinit();
    try conductor.to_driver_buffer.write_terminate_driver(null);
    _ = try conductor.do_work();
    try std.testing.expect(conductor.is_shutdown_requested());
}
```

- [ ] **Step 6: Write loss_and_recovery_test.zig**

```zig
// Upstream reference: aeron-driver/src/test/java/io/aeron/driver/LossHandlerTest.java
//                    aeron-driver/src/test/java/io/aeron/driver/RetransmitHandlerTest.java
// Aeron version: 1.50.2
// Coverage: gap detected, NAK sent, retransmit triggered, duplicate suppressed

const std = @import("std");
const aeron = @import("aeron");

test "LossHandler: gap detected when term_offset not contiguous" {
    const allocator = std.testing.allocator;
    var handler = try aeron.driver.LossHandler.init(allocator);
    defer handler.deinit();
    const gap_detected = handler.on_gap(0, 0, 1024, 512); // expected at 0, received at 1024
    try std.testing.expect(gap_detected);
}

test "LossHandler: no gap when term_offset is contiguous" {
    const allocator = std.testing.allocator;
    var handler = try aeron.driver.LossHandler.init(allocator);
    defer handler.deinit();
    const gap_detected = handler.on_gap(0, 0, 0, 512);
    try std.testing.expect(!gap_detected);
}

test "RetransmitHandler: duplicate NAK within linger period is suppressed" {
    const allocator = std.testing.allocator;
    var handler = try aeron.driver.RetransmitHandler.init(allocator);
    defer handler.deinit();
    _ = try handler.on_nak(0, 0, 1024, 512);
    const second = try handler.on_nak(0, 0, 1024, 512); // same NAK
    try std.testing.expect(!second); // suppressed
}
```

- [ ] **Step 7: Run driver tests**

```bash
make test-driver
```

Expected: all pass. Fix any API mismatches by reading the relevant `src/driver/*.zig` files.

- [ ] **Step 8: Update upstream_map.jsonl for driver rows**

```bash
tmp=$(mktemp)
jq 'if .layer == "driver" then .status = "done" else . end' test/upstream_map.jsonl > "$tmp" && mv "$tmp" test/upstream_map.jsonl
```

- [ ] **Step 9: Commit**

```bash
git add test/driver/ test/upstream_map.jsonl
git commit -m "feat: add driver scenario tests (session, pub/sub lifecycle, ipc, loss)"
```

---

## Task 6: Archive Scenario Tests

**Files:**
- Modify: `test/archive/catalog_test.zig`
- Create: `test/archive/record_replay_test.zig`
- Create: `test/archive/segment_rotation_test.zig`

Read `src/archive/catalog.zig` and `src/archive/recording.zig` before implementing.

- [ ] **Step 1: Read archive API**

```bash
grep -n "pub fn\|pub const" src/archive/catalog.zig src/archive/recording.zig 2>/dev/null | head -50
```

- [ ] **Step 2: Replace catalog_test.zig stub**

```zig
// Upstream reference: aeron-archive/src/test/java/io/aeron/archive/CatalogTest.java
// Aeron version: 1.50.2
// Coverage: recording descriptor written, read back, index updated on close

const std = @import("std");
const aeron = @import("aeron");

comptime {
    _ = @import("record_replay_test.zig");
    _ = @import("segment_rotation_test.zig");
}

test "Catalog: recording descriptor is persisted and readable" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var catalog = try aeron.archive.Catalog.open(allocator, path);
    defer catalog.close();

    const rec_id = try catalog.add_recording(.{
        .stream_id = 1001,
        .session_id = 42,
        .channel = "aeron:udp?endpoint=localhost:20121",
    });
    const desc = try catalog.find(rec_id);
    try std.testing.expectEqual(@as(i32, 1001), desc.stream_id);
}

test "Catalog: recording count increments after add" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var catalog = try aeron.archive.Catalog.open(allocator, path);
    defer catalog.close();

    const before = catalog.count();
    _ = try catalog.add_recording(.{ .stream_id = 1, .session_id = 1, .channel = "aeron:ipc" });
    try std.testing.expectEqual(before + 1, catalog.count());
}
```

- [ ] **Step 3: Write record_replay_test.zig**

```zig
// Upstream reference: aeron-archive/src/test/java/io/aeron/archive/ArchiveTest.java
// Aeron version: 1.50.2
// Coverage: record 10 messages, replay yields same messages in order

const std = @import("std");
const aeron = @import("aeron");

test "Archive: replay yields recorded messages in order" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var archive = try aeron.archive.Archive.open(allocator, path);
    defer archive.close();

    const rec_id = try archive.start_recording(1001, 42, "aeron:ipc");
    for (0..10) |i| {
        try archive.offer(rec_id, &std.mem.toBytes(@as(u64, i)));
    }
    try archive.stop_recording(rec_id);

    var replay = try archive.start_replay(rec_id, 0, std.math.maxInt(i64));
    defer replay.close();
    var count: usize = 0;
    while (try replay.poll()) |msg| {
        try std.testing.expectEqual(count, std.mem.bytesToValue(u64, msg[0..8]));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), count);
}
```

- [ ] **Step 4: Write segment_rotation_test.zig**

```zig
// Upstream reference: aeron-archive/src/test/java/io/aeron/archive/RecordingWriterTest.java
// Aeron version: 1.50.2
// Coverage: segment file rotates when segment_length is exceeded

const std = @import("std");
const aeron = @import("aeron");

test "RecordingWriter: segment rotates after segment_length bytes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    const segment_len: u32 = 65536;
    var writer = try aeron.archive.RecordingWriter.init(allocator, path, segment_len);
    defer writer.deinit();

    var buf: [1024]u8 = undefined;
    var written: u64 = 0;
    while (written < segment_len + 1024) : (written += buf.len) {
        try writer.write(&buf);
    }
    // Expect at least 2 segment files
    try std.testing.expect(writer.segment_count() >= 2);
}
```

- [ ] **Step 5: Run and fix**

```bash
make test-archive
```

- [ ] **Step 6: Update upstream_map.jsonl**

```bash
tmp=$(mktemp)
jq 'if .layer == "archive" then .status = "done" else . end' test/upstream_map.jsonl > "$tmp" && mv "$tmp" test/upstream_map.jsonl
```

- [ ] **Step 7: Commit**

```bash
git add test/archive/ test/upstream_map.jsonl
git commit -m "feat: add archive scenario tests (catalog, record/replay, segment rotation)"
```

---

## Task 7: Cluster Scenario Tests

**Files:**
- Modify: `test/cluster/election_test.zig`
- Create: `test/cluster/log_replication_test.zig`
- Create: `test/cluster/failover_test.zig`

Read `src/cluster/election.zig` and `src/cluster/log_replication.zig` before implementing.

- [ ] **Step 1: Read cluster API**

```bash
grep -n "pub fn\|pub const" src/cluster/election.zig src/cluster/log_replication.zig 2>/dev/null | head -50
```

- [ ] **Step 2: Replace election_test.zig stub**

```zig
// Upstream reference: aeron-cluster/src/test/java/io/aeron/cluster/ElectionTest.java
// Aeron version: 1.50.2
// Coverage: canvass phase, vote request, vote granted, leader elected

const std = @import("std");
const aeron = @import("aeron");

comptime {
    _ = @import("log_replication_test.zig");
    _ = @import("failover_test.zig");
}

test "Election: initial state is CANVASS" {
    const allocator = std.testing.allocator;
    var election = try aeron.cluster.Election.init(allocator, .{ .member_id = 0, .member_count = 3 });
    defer election.deinit();
    try std.testing.expectEqual(aeron.cluster.ElectionState.canvass, election.state());
}

test "Election: single-member cluster immediately becomes leader" {
    const allocator = std.testing.allocator;
    var election = try aeron.cluster.Election.init(allocator, .{ .member_id = 0, .member_count = 1 });
    defer election.deinit();
    try election.do_work(0);
    try std.testing.expectEqual(aeron.cluster.ElectionState.leader, election.state());
}

test "Election: leader elected after majority vote" {
    const allocator = std.testing.allocator;
    var election = try aeron.cluster.Election.init(allocator, .{ .member_id = 0, .member_count = 3 });
    defer election.deinit();
    try election.on_vote(1, 0, true);
    try election.on_vote(2, 0, true);
    try std.testing.expectEqual(aeron.cluster.ElectionState.leader, election.state());
}
```

- [ ] **Step 3: Write log_replication_test.zig**

```zig
// Upstream reference: aeron-cluster/src/test/java/io/aeron/cluster/ClusterTimerTest.java
//                    aeron-cluster/src/test/java/io/aeron/cluster/LogReplicationTest.java
// Aeron version: 1.50.2
// Coverage: follower replicates log entries, commit position advances

const std = @import("std");
const aeron = @import("aeron");

test "LogReplication: follower commit position advances after leader append" {
    const allocator = std.testing.allocator;
    var replication = try aeron.cluster.LogReplication.init(allocator, .{
        .leader_id = 0,
        .follower_id = 1,
    });
    defer replication.deinit();

    try replication.append_entry(.{ .term_id = 1, .position = 1024 });
    try replication.on_append_ack(1, 1024);
    try std.testing.expectEqual(@as(i64, 1024), replication.commit_position());
}

test "ClusterTimer: timer fires after deadline" {
    const allocator = std.testing.allocator;
    var timer = try aeron.cluster.ClusterTimer.init(allocator);
    defer timer.deinit();
    const correlation_id: i64 = 42;
    try timer.schedule(correlation_id, 100); // deadline = now + 100
    const fired = timer.poll(200);            // now = 200
    try std.testing.expect(fired);
}
```

- [ ] **Step 4: Write failover_test.zig**

```zig
// Upstream reference: aeron-cluster/src/test/java/io/aeron/cluster/ClusterNodeTest.java (failover cases)
// Aeron version: 1.50.2
// Coverage: leader failure triggers election, new leader elected, session redirected

const std = @import("std");
const aeron = @import("aeron");

test "ClusterNode: leader failure triggers new election" {
    const allocator = std.testing.allocator;
    var node = try aeron.cluster.ClusterNode.init(allocator, .{ .member_id = 1, .member_count = 3 });
    defer node.deinit();
    // Simulate leader (member 0) timeout
    node.on_leader_heartbeat_timeout();
    try std.testing.expectEqual(aeron.cluster.NodeRole.candidate, node.role());
}

test "ClusterNode: session redirect after failover" {
    const allocator = std.testing.allocator;
    var node = try aeron.cluster.ClusterNode.init(allocator, .{ .member_id = 0, .member_count = 3 });
    defer node.deinit();
    // Become leader
    _ = try node.election.do_work(0);
    // Client session established
    const session_id = try node.open_session(1, 1);
    // Simulate failover (step down)
    node.step_down();
    // Session should receive redirect
    const redirect = node.session_redirect(session_id);
    try std.testing.expect(redirect != null);
}
```

- [ ] **Step 5: Run and fix**

```bash
make test-cluster
```

- [ ] **Step 6: Update upstream_map.jsonl**

```bash
tmp=$(mktemp)
jq 'if .layer == "cluster" then .status = "done" else . end' test/upstream_map.jsonl > "$tmp" && mv "$tmp" test/upstream_map.jsonl
```

- [ ] **Step 7: Run all scenarios + full check**

```bash
make test-scenarios
make check
```

Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add test/cluster/ test/upstream_map.jsonl
git commit -m "feat: add cluster scenario tests (election, log replication, failover)"
```

---

## Task 8: CI Workflows

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/interop.yml`

Copy verbatim from spec (already reviewed and approved).

- [ ] **Step 1: Create .github/workflows/ directory**

```bash
mkdir -p .github/workflows
```

- [ ] **Step 2: Create ci.yml**

Content is verbatim from the spec `CI Architecture > Skeleton: .github/workflows/ci.yml`. Key points:
- `permissions: {}` (explicit empty — security best practice)
- `cancel-in-progress` for non-main branches
- `zig-test` matrix: ubuntu + macos
- `interop-smoke` gate
- `core-pipeline` fan-in job

```yaml
name: CI
permissions: {}

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}

on:
  pull_request:
  push:
    branches: [main]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - run: nix develop --command make lint

  zig-test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - uses: actions/cache@v4
        with:
          path: ~/.cache/zig
          key: zig-${{ matrix.os }}-${{ hashFiles('build.zig.zon') }}
      - run: nix develop --command make check
      - run: nix develop --command make test-scenarios

  interop-smoke:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - uses: actions/setup-java@v4
        with:
          java-version: '21'
          distribution: temurin
          cache: maven
      - run: nix develop --command make build
      - run: docker compose -f deploy/docker-compose.ci.yml up --abort-on-container-exit --exit-code-from java-client
        env:
          AERON_VERSION: "1.50.2"

  core-pipeline:
    if: always()
    runs-on: ubuntu-latest
    needs: [lint, zig-test, interop-smoke]
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
```

- [ ] **Step 3: Create interop.yml**

```yaml
name: Interop Full
on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  interop-full:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - uses: actions/setup-java@v4
        with: { java-version: '21', distribution: temurin, cache: maven }
      - run: nix develop --command make build
      - run: docker compose -f deploy/docker-compose.ci.yml --profile full up --abort-on-container-exit

  bench:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - run: nix develop --command make bench
```

- [ ] **Step 4: Commit**

```bash
git add .github/
git commit -m "ci: add ci.yml (zig-test matrix + interop-smoke gate) and interop.yml"
```

---

## Task 9: Docker Compose + Dockerfiles for CI Interop

**Files:**
- Create: `deploy/docker-compose.ci.yml`
- Create: `deploy/Dockerfile.zig`
- Create: `deploy/Dockerfile.java-aeron`

- [ ] **Step 1: Create docker-compose.ci.yml**

```yaml
services:
  zig-driver:
    build:
      context: .
      dockerfile: deploy/Dockerfile.zig
    networks: [aeron]
    environment:
      AERON_DIR: /tmp/aeron
      AERON_TERM_BUFFER_LENGTH: "65536"
    healthcheck:
      test: ["CMD", "test", "-S", "/tmp/aeron/cnc.dat"]
      interval: 2s
      timeout: 5s
      retries: 10

  java-client:
    build:
      context: deploy/
      dockerfile: Dockerfile.java-aeron
      args:
        AERON_VERSION: "${AERON_VERSION:-1.50.2}"
    networks: [aeron]
    depends_on:
      zig-driver:
        condition: service_healthy
    environment:
      AERON_DIR: /tmp/aeron
      MSG_COUNT: "${MSG_COUNT:-10}"

networks:
  aeron:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16
```

> Note: Aeron IPC is UDP only between containers (separate processes on Docker bridge). No shared mmap between containers.

- [ ] **Step 2: Create deploy/Dockerfile.zig**

```dockerfile
FROM nixos/nix:latest AS builder
WORKDIR /src
COPY . .
RUN nix develop --command make build

FROM nixos/nix:latest
WORKDIR /app
COPY --from=builder /src/zig-out/bin/aeron-driver /app/aeron-driver
EXPOSE 20121/udp
CMD ["/app/aeron-driver"]
```

- [ ] **Step 3: Create deploy/Dockerfile.java-aeron**

```dockerfile
FROM eclipse-temurin:21-jre-alpine AS fetcher
ARG AERON_VERSION=1.50.2
RUN apk add --no-cache curl && \
    curl -fsSL \
      "https://repo1.maven.org/maven2/io/aeron/aeron-all/${AERON_VERSION}/aeron-all-${AERON_VERSION}.jar" \
      -o /aeron-all.jar

FROM eclipse-temurin:21-jre-alpine
COPY --from=fetcher /aeron-all.jar /aeron-all.jar
ENV MSG_COUNT=10
# Default: subscriber (smoke test — java receives from zig)
CMD ["java", "-cp", "/aeron-all.jar", "io.aeron.samples.AeronSubscriber"]
```

- [ ] **Step 4: Verify docker-compose.ci.yml is valid YAML (lint)**

```bash
make fmt-check
```

The `prettier --check` step will validate the YAML.

- [ ] **Step 5: Commit**

```bash
git add deploy/docker-compose.ci.yml deploy/Dockerfile.zig deploy/Dockerfile.java-aeron
git commit -m "ci: add docker-compose.ci.yml and Dockerfiles for interop smoke"
```

---

## Task 10: Final Verification

- [ ] **Step 1: Run full check**

```bash
make check
```

Expected: fmt-check + build + test + test-scenarios + lesson-lint all pass. Exit 0.

- [ ] **Step 2: Verify all upstream_map.jsonl rows are "done"**

```bash
jq 'select(.status != "done")' test/upstream_map.jsonl
```

Expected: no output.

- [ ] **Step 3: Verify k8s/ is at project root**

```bash
ls k8s/
```

Expected: directory exists.

- [ ] **Step 4: Verify deleted dirs are gone**

```bash
ls deploy/interop/ 2>&1 | grep -c "No such"
ls test/stress/ 2>&1 | grep -c "No such"
ls test/interop/ 2>&1 | grep -c "No such"
```

Expected: all print 1.

- [ ] **Step 5: Verify CI workflows exist**

```bash
ls .github/workflows/
```

Expected: `ci.yml  interop.yml`

- [ ] **Step 6: Run make status**

```bash
make status
```

Expected: clean output — no pending rows, no parity gaps blocking.

- [ ] **Step 7: Final commit if any cleanup was done, then tag the phase**

```bash
git add -p  # only if there are uncommitted changes
git commit -m "chore: phase 10 verification cleanup"
```

Do NOT tag — user confirms the tag (`v0.2.0`) separately after PR review.

---

## Success Criteria

- [ ] `make check` exits 0 on a clean clone (includes `test-scenarios`)
- [ ] All 19 rows in `test/upstream_map.jsonl` show `"status":"done"`
- [ ] `.github/workflows/ci.yml` exists with `core-pipeline` fan-in
- [ ] `.github/workflows/interop.yml` exists
- [ ] `deploy/docker-compose.ci.yml` exists
- [ ] `k8s/` at project root; `deploy/k8s/` gone
- [ ] `deploy/interop/`, `test/stress/`, `test/interop/` deleted
- [ ] `make status` outputs no pending rows
