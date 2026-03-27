# Publication Path Tracker

Branch: `docs/publication-path-parity-plan`
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
- [~] `make interop-smoke` now gets past log-buffer mapping and fails later on publication connectivity.

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
| P11-8 | interop | Heisenberg (5.4-mini) + Lead | blocked | `deploy/InteropSmoke.java`, `deploy/entrypoint-java.sh`, `deploy/docker-compose.ci.yml` | Finite smoke now exercises addSubscription + addPublication + bounded publish path, but publication remains disconnected |
| P11-9 | verification | Lead | in progress | `Makefile`, `.agents/PUBLICATION_PATH_TRACKER.md`, `.agents/publication_path_tasks.jsonl` | `make check` passed; `make interop-smoke` still blocked on publication connectivity |

## Evidence / Upstream References

- `vendor/aeron/aeron-client/src/main/java/io/aeron/command/CorrelatedMessageFlyweight.java`
- `vendor/aeron/aeron-client/src/main/java/io/aeron/command/PublicationMessageFlyweight.java`
- `vendor/aeron/aeron-client/src/main/java/io/aeron/command/PublicationBuffersReadyFlyweight.java`
- `vendor/aeron/aeron-client/src/main/java/io/aeron/DriverProxy.java`
- `vendor/aeron/aeron-client/src/main/java/io/aeron/DriverEventsAdapter.java`
- `vendor/aeron/aeron-client/src/test/c/aeron_client_conductor_test.cpp`

## Risks / Open Questions

- Local publication buffers are not consistently represented as stable on-disk log files yet; the ready payload needs a credible `log_file_name` story.
- Embedded-driver lookup by `(session_id, stream_id)` currently papers over missing wire metadata.
- The bounded interop smoke now reaches Java publication creation and log-buffer mapping, but the publication never reaches `isConnected()`. The next likely boundary is sender/receiver/image/status connectivity rather than control-plane wire shape.

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
