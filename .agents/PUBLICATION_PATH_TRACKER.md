# Publication Path Tracker

Branch: `fix/counters-metadata-parity`
Date started: 2026-03-27

## Legend
- [ ] pending
- [x] done
- [~] in progress
- [!] blocked

---

## Objective

Make the next parity slice concrete and agent-ready: publication command/response fidelity first, then finite publish/data-path interop coverage.

## Success Criteria

- `ADD_PUBLICATION` request is spec-locked against vendored upstream.
- `ON_PUBLICATION_READY` response matches upstream field shape.
- Client publication creation consumes the full ready payload.
- A finite publication-oriented interop check exists.
- Status is queryable locally via JSONL.

## Status Snapshot

- [x] Session resumed from MCP and local docs.
- [x] Next gap confirmed from local context: publication-path parity after Phase 10.
- [x] Feature branch created before writing docs.
- [x] Upstream publication contract summarized from `vendor/aeron`.
- [x] Local implementation/task split documented.
- [x] Publication-ready payload now carries upstream fields plus a mappable log-buffer path.
- [x] `make check` is green after the publication-path wire/client changes.
- [x] `make interop-smoke` is green for finite Java publication + subscription data-path flow.
- [x] Publication-window, image-log mapping, and client-owned subscriber-position gaps were closed locally.
- [x] Remaining upstream parity backlog was narrowed to counters metadata/type-id compatibility.
- [x] Agrona-compatible counters metadata/type-id cleanup is done on the follow-up branch.
- [x] External Java `countersReader()` validation is green, including channel-status counters and counter-id handoff.

## Task Board

| ID | Lane | Owner | Status | Files | Notes |
|----|------|-------|--------|-------|-------|
| P11-1 | upstream-contract | Hilbert (5.4-mini) | done | `vendor/aeron/.../PublicationMessageFlyweight.java`, `vendor/aeron/.../PublicationBuffersReadyFlyweight.java`, `vendor/aeron/.../DriverProxy.java`, `vendor/aeron/.../DriverEventsAdapter.java` | Exact field order confirmed locally from vendored Aeron 1.50.2 |
| P11-2 | local-gap-analysis | Lead | done | `src/aeron.zig`, `src/driver/conductor.zig`, `src/driver/media_driver.zig`, `test/driver/conductor_test.zig` | Request layout is close; ready response and client materialization are simplified |
| P11-3 | plan-doc | Lead | done | `docs/plans/2026-03-27-publication-path-upstream-parity.md` | Durable execution plan for the next slice |
| P11-4 | tracker-doc | Lead | done | `.agents/PUBLICATION_PATH_TRACKER.md`, `.agents/publication_path_tasks.jsonl` | Local coordination and machine-queryable status |
| P11-5 | conductor-response | Lead | done | `src/driver/conductor.zig`, `src/logbuffer/log_buffer.zig`, `src/driver/media_driver.zig` | `ON_PUBLICATION_READY` now emits registration id, both counter ids, and a log-buffer path; mapped file metadata is initialized for Java log-buffer mapping |
| P11-6 | client-ready-consumption | Lead | done | `src/aeron.zig`, `src/publication.zig` | Client parses the full ready payload and can map the returned log buffer |
| P11-7 | tests | Lead | done | `src/aeron.zig`, `src/driver/conductor.zig`, `test/driver/conductor_test.zig` | Local tests and `make check` are green after the publication-path change set |
| P11-8 | interop | Heisenberg (5.4-mini) + Lead | done | `deploy/InteropSmoke.java`, `src/driver/conductor.zig`, `src/driver/media_driver.zig`, `src/driver/sender.zig`, `src/driver/receiver.zig`, `src/ipc/counters.zig` | Smoke is green after fixing publisher-limit visibility, mapped image log delivery, image metadata init, and client-owned subscriber-position semantics |
| P11-9 | verification | Lead | done | `Makefile`, `.agents/PUBLICATION_PATH_TRACKER.md`, `.agents/publication_path_tasks.jsonl` | `make test-unit`, `make check`, and `make interop-smoke` are green |
| P12-1 | counters-parity | Lead + Ramanujan | done | `src/ipc/counters.zig`, `src/driver/conductor.zig`, `src/tools/streams.zig` | Agrona-compatible metadata layout and Aeron counter type ids are aligned locally |
| P12-2 | verification | Lead | done | `Makefile`, `test/integration_test.zig`, `.agents/PUBLICATION_PATH_TRACKER.md`, `.agents/publication_path_tasks.jsonl` | `make check` is green after the counters metadata follow-up |
| P12-3 | external-reader-validation | Lead + Arendt | done | `deploy/InteropSmoke.java`, `src/driver/conductor.zig`, `src/ipc/counters.zig`, `test/driver/conductor_test.zig`, `test/integration_test.zig` | Java now validates real `countersReader()` semantics, including channel-status ids and channel-key metadata |

## Evidence / Upstream References

- `vendor/aeron/aeron-client/src/main/java/io/aeron/command/CorrelatedMessageFlyweight.java`
- `vendor/aeron/aeron-client/src/main/java/io/aeron/command/PublicationMessageFlyweight.java`
- `vendor/aeron/aeron-client/src/main/java/io/aeron/command/PublicationBuffersReadyFlyweight.java`
- `vendor/aeron/aeron-client/src/main/java/io/aeron/DriverProxy.java`
- `vendor/aeron/aeron-client/src/main/java/io/aeron/DriverEventsAdapter.java`
- `vendor/aeron/aeron-client/src/test/c/aeron_client_conductor_test.cpp`

## Risks / Open Questions

- Remaining parity debt is now narrower: the core counters metadata and Java-reader path are validated locally, but broader downstream tooling beyond `InteropSmoke.java` still needs external-reader coverage.
- Embedded-driver lookup by `(session_id, stream_id)` still exists as fallback in the Zig client, although the wire path is now sufficient for external Java publication/subscription smoke.
- Receiver-side subscriber position semantics are now aligned enough for Java image polling, but the broader counters metadata surface should still be normalized against vendored Aeron before calling this area fully upstream-parity complete.

## Session Log

### 2026-03-27
- Loaded MCP project/session state first.
- Confirmed current starting point: `main` had Phase 10 merged and a clean tracked next step.
- Found an existing local modification in `.agents/CONTEXT.md` and left it untouched.
- Created `docs/publication-path-parity-plan` before editing.
- Dispatched parallel research lanes for upstream contract, local code gaps, and documentation/status structure.
- Recorded the next execution slice as publication-path upstream parity with four implementation lanes: conductor, client, tests, interop.

### 2026-03-27 - implementation follow-up
- Cleared the stale local `.agents/CONTEXT.md` diff at the user's request.
- Switched onto `feat/publication-path-upstream-parity` before code edits.
- Saved the working-style preference locally under `.agents/USER_PREFERENCES.md` and `.agents/MEMORY.md`.
- Expanded `ON_PUBLICATION_READY` to the upstream field shape and returned a real mapped log-buffer path.
- Initialized mapped publication log-buffer metadata enough for Java to open the file successfully.
- Updated the Zig client to parse the full ready payload and map the returned log buffer.
- `make check` passed.
- `make interop-smoke` advanced from log-buffer mapping failure to `Timed out waiting for publication to connect`.

### 2026-03-27 - interop follow-up
- Fixed publication log metadata offsets to upstream `LogBufferDescriptor` values, which cleared the Java `term length = 0` mapping failure.
- Added publication log metadata connected/active-transport state and updated it from sender STATUS handling.
- Reworked loopback interop so the driver emits an initial SETUP immediately and reaches receiver-side SETUP processing and image creation.
- Expanded `ON_IMAGE_READY` from the previous 20-byte stub to the upstream `ImageBuffersReadyFlyweight` field layout used by the Java client.
- Switched counter value stride to `128` bytes so Java sees the correct publisher-limit slot instead of stalling after the first offer.
- Moved image delivery onto a mapped image log file, initialized its metadata, and advertised that file in `ON_IMAGE_READY`.
- Stopped using the client-visible subscriber-position counter as receiver rebuild progress; Java now owns image consumption position and finite subscription polling succeeds.
- `make test-unit`, `make check`, and `make interop-smoke` are green.

### 2026-03-27 - counters parity follow-up
- Switched to `fix/counters-metadata-parity` from clean `main` after the publication-path PR landed.
- Normalized `src/ipc/counters.zig` toward Agrona/CountersReader layout: `METADATA_LENGTH=512`, `KEY_OFFSET=16`, `LABEL_OFFSET=128`, `MAX_KEY_LENGTH=112`, `MAX_LABEL_LENGTH=380`, and value-record registration/owner/reference offsets.
- Corrected Aeron driver counter type ids to upstream values for publisher limit, sender position, receiver HWM, subscriber position, and channel status.
- Added upstream-style stream-counter key/value metadata population and updated local stream reporting to read stream identity from the metadata key before falling back to labels.
- Updated the integration expectation so it asserts the corrected ownership boundary: driver-side inserts must not advance the client-owned subscriber-position counter.
- `make check` is green on the follow-up branch.

### 2026-03-27 - external reader verification follow-up
- Added upstream-shaped channel-status counter allocation so publication and subscription channel status carry registration metadata plus channel-key metadata.
- `ON_SUBSCRIPTION_READY` now returns a real receive-channel-status counter id instead of `NULL_COUNTER_ID`.
- Tightened `deploy/InteropSmoke.java` to validate publisher-limit, sender-position, receiver-HWM, subscriber-position, and both channel-status counters through Java `countersReader()` and `channelStatusId()`.
- Repaired affected driver and integration tests so the new channel-status contract is covered locally.
- `make interop-smoke` and `make check` are green on `fix/counters-metadata-parity`.
