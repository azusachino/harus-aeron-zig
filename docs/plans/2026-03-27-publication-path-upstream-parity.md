# Publication Path Upstream Parity Plan

> For agentic workers: keep this scope narrow. The immediate objective is publication-path parity only: `ADD_PUBLICATION`, `ON_PUBLICATION_READY`, and a finite publish/data-path interop proof.

**Goal:** close the next post-Phase-10 parity gap by making publication creation and readiness behave like upstream Aeron 1.50.2 instead of the current simplified embedded-driver shortcut.

**Architecture:** the client already emits `ADD_PUBLICATION` in upstream field order, but the driver response and client-side publication materialization are still reduced. The driver must emit the full `PublicationBuffersReadyFlyweight`-compatible payload, and the client must consume it as the contract for publication readiness.

**Tech Stack:** Zig 0.15.2, Nix devShell, vendored Aeron `1.50.2`, local `vendor/aeron` source as the canonical contract, `make check`, `make interop-smoke`.

---

## Upstream Contract

Primary local references:
- `vendor/aeron/aeron-client/src/main/java/io/aeron/command/CorrelatedMessageFlyweight.java`
- `vendor/aeron/aeron-client/src/main/java/io/aeron/command/PublicationMessageFlyweight.java`
- `vendor/aeron/aeron-client/src/main/java/io/aeron/command/PublicationBuffersReadyFlyweight.java`
- `vendor/aeron/aeron-client/src/main/java/io/aeron/DriverProxy.java`
- `vendor/aeron/aeron-client/src/main/java/io/aeron/DriverEventsAdapter.java`
- `vendor/aeron/aeron-client/src/test/c/aeron_client_conductor_test.cpp`

Required wire shapes:

1. `ADD_PUBLICATION`
   - `client_id:i64`
   - `correlation_id:i64`
   - `stream_id:i32`
   - `channel_length:i32`
   - `channel_bytes`

2. `ON_PUBLICATION_READY`
   - `correlation_id:i64`
   - `registration_id:i64`
   - `session_id:i32`
   - `stream_id:i32`
   - `publication_limit_counter_id:i32`
   - `channel_status_counter_id:i32`
   - `log_file_name_length:i32`
   - `log_file_name_bytes`

---

## Current Local Gaps

1. `src/aeron.zig` already writes `ADD_PUBLICATION` in the correct upstream order, but only minimal byte checks exist.
2. `src/driver/conductor.zig` `sendPublicationReady` currently sends only 20 bytes:
   - `correlation_id`
   - `session_id`
   - `stream_id`
   - `publication_limit_counter_id`
3. The current ready response omits:
   - `registration_id`
   - `channel_status_counter_id`
   - `log_file_name`
4. `src/aeron.zig` currently parses that truncated response and reconstructs publications by asking the embedded driver for a log buffer via `(session_id, stream_id)`.
5. The current smoke path validates subscription readiness only; it does not prove an upstream-faithful publication-ready path.

---

## File Ownership

| Lane | Files |
|------|-------|
| Wire contract | `src/driver/conductor.zig`, `src/aeron.zig` |
| Publication materialization | `src/aeron.zig`, `src/publication.zig`, `src/driver/media_driver.zig`, `src/logbuffer/log_buffer.zig` |
| Spec-locked tests | `src/aeron.zig`, `src/driver/conductor.zig`, `test/driver/conductor_test.zig`, related scenario tests |
| Interop proof | `deploy/InteropSmoke.java`, `deploy/entrypoint-java.sh`, `deploy/docker-compose.ci.yml`, `Makefile` if needed |
| Team tracking | `.agents/PUBLICATION_PATH_TRACKER.md`, `.agents/publication_path_tasks.jsonl` |

---

## Task 1: Lock the Upstream Byte Contract

**Files:**
- `src/aeron.zig`
- `src/driver/conductor.zig`
- `test/driver/conductor_test.zig`

- [ ] Add explicit byte-layout assertions for `ADD_PUBLICATION` length and field order using vendored Aeron flyweight structure as the source of truth.
- [ ] Add explicit byte-layout assertions for `ON_PUBLICATION_READY` including `registration_id`, both counter ids, and the ASCII `log_file_name`.
- [ ] Reject malformed publication-ready payloads on the client side rather than assuming the reduced local shape.

Acceptance:
- `make test-unit`

---

## Task 2: Emit an Upstream-Faithful `ON_PUBLICATION_READY`

**Files:**
- `src/driver/conductor.zig`
- `src/logbuffer/log_buffer.zig`
- `src/driver/media_driver.zig`

- [ ] Extend publication tracking so the conductor can emit both `registration_id` and a stable log-buffer file name.
- [ ] Add a channel-status counter id for publication readiness instead of omitting it from the contract.
- [ ] Replace the current 20-byte ready message with the upstream-ready payload shape.
- [ ] Preserve embedded-driver behavior while making the wire payload complete enough for external clients.

Acceptance:
- `make test-unit`
- `make check`

---

## Task 3: Consume the Full Ready Contract in the Client

**Files:**
- `src/aeron.zig`
- `src/publication.zig`
- `src/driver/media_driver.zig`

- [ ] Parse `registration_id`, `session_id`, `stream_id`, both counter ids, and `log_file_name` from `RESPONSE_ON_PUBLICATION_READY`.
- [ ] Stop depending on the reduced `(session_id, stream_id)` lookup as the only publication materialization path.
- [ ] Use the ready response as the source of truth for publication registration and counter attachment.
- [ ] Keep embedded-driver tests green while moving toward a path that can support external clients.

Acceptance:
- `make test-unit`
- `make check`

---

## Task 4: Add Finite Publish/Data-Path Interop Coverage

**Files:**
- `deploy/InteropSmoke.java`
- `deploy/entrypoint-java.sh`
- `deploy/docker-compose.ci.yml`
- `Makefile` if target wiring changes

- [ ] Extend the finite Java smoke helper beyond `addSubscription` so publication creation is exercised explicitly.
- [ ] Add a bounded publish/data-path scenario that proves a publication becomes usable after the ready response.
- [ ] Keep the smoke harness finite and CI-appropriate.

Acceptance:
- `make interop-smoke`

---

## Task 5: Verification and Closeout

**Files:**
- tracking docs plus any touched source/tests

- [ ] Run `make check`.
- [ ] Run `make interop-smoke`.
- [ ] Update `.agents/publication_path_tasks.jsonl` and `.agents/PUBLICATION_PATH_TRACKER.md` with final status.
- [ ] If this slice stabilizes, fold the result back into `docs/plan.md` as the next completed parity step.

---

## Dependencies and Parallelism

- Task 1 can start immediately.
- Task 2 depends on Task 1 contract lock-in.
- Task 3 depends on Task 2 payload shape.
- Task 4 can prepare harness changes in parallel with Tasks 2 and 3, but final verification depends on both.
- Task 5 is last.

Recommended parallel split:
- Agent A: upstream contract plus byte-locked tests
- Agent B: conductor response payload and publication metadata plumbing
- Agent C: client ready parsing and publication construction
- Agent D: finite interop harness extension

---

## Risks

1. Publication readiness now needs a stable log-file identity, but local publication buffers are still often heap-backed instead of clearly file-backed.
2. The embedded-driver helper path may hide external-client gaps unless tests assert the ready payload directly.
3. Adding the full ready payload can break existing simplified tests unless they are updated in the same slice.

## Done When

- The driver emits the upstream `PublicationBuffersReadyFlyweight` field set.
- The client consumes that full field set.
- Byte-level tests lock both request and response layouts.
- A finite publish/data-path interop check passes locally.
