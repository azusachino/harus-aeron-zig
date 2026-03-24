# Implementation Plan — harus-aeron-zig

Reference: https://github.com/aeron-io/aeron

Each task is sized for a single agent session (~1-4h). Tasks within a phase that have no
stated dependencies can be executed in parallel by multiple agents.

---

## Phase 1 — Media Driver (MVP)

Goal: wire-compatible Aeron UDP pub/sub. A publisher on our driver can send to a subscriber
on the real Java Aeron driver and vice versa.

Key reference files in the upstream repo:
- `aeron-driver/src/main/c/protocol/aeron_udp_protocol.h` — all frame layouts
- `aeron-client/src/main/java/io/aeron/logbuffer/LogBufferDescriptor.java` — log buffer metadata
- `aeron-driver/src/main/java/io/aeron/driver/` — Conductor, Sender, Receiver

---

### Task P1-1: Protocol Frame Codec (no deps)

**File**: `src/protocol/frame.zig`

Complete the frame codec layer. Everything must use `extern struct` with comptime size assertions.

Implement:
- `FrameHeader` (8 bytes) — base header
- `DataHeader` (32 bytes) — BEGIN/END/EOS flags
- `SetupHeader` (40 bytes) — initial_term_id, active_term_id, term_length, mtu, ttl
- `StatusMessage` (36 bytes) — consumption_term_id/offset, receiver_window, receiver_id
- `NakHeader` (28 bytes) — term_id, term_offset, length
- `RttMeasurement` (24 bytes) — echo_timestamp, reception_delta, receiver_id
- `ResolutionEntry` — for address resolution

Helper functions:
- `alignedLength(data_length: usize) usize` — frame_length padded to FRAME_ALIGNMENT (32)
- `computeMaxPayload(mtu: usize) usize` — mtu minus DataHeader.LENGTH
- `isBeginFragment(flags: u8) bool`
- `isEndFragment(flags: u8) bool`

All frame types must pass `comptime { std.debug.assert(@sizeOf(T) == expected); }`.
Write unit tests for every helper function.

Reference: `aeron-driver/src/main/c/protocol/aeron_udp_protocol.h`

---

### Task P1-2: Log Buffer — Metadata & Term Rotation (no deps)

**Files**: `src/logbuffer/metadata.zig`, `src/logbuffer/log_buffer.zig`

Implement the log buffer metadata section and term rotation logic.

Constants (from `LogBufferDescriptor`):
- `PARTITION_COUNT = 3`
- `TERM_MIN_LENGTH = 64 * 1024`
- `TERM_MAX_LENGTH = 1024 * 1024 * 1024`
- `TERM_TAIL_COUNTERS_OFFSET`, `LOG_ACTIVE_TERM_COUNT_OFFSET`, etc.
- `LOG_META_DATA_LENGTH` — must be cache-line aligned (align to 4096)

`LogBufferMetadata` struct (backed by last partition of mmap file):
- `activeTermCount() i32` — atomic load
- `setActiveTermCount(val: i32)` — atomic store
- `rawTailVolatile(partition: usize) i64` — atomic load of tail counter
- `termId(raw_tail: i64) i32` — high 32 bits
- `termOffset(raw_tail: i64, term_length: i32) i32` — low 32 bits clamped to term_length
- `activePartitionIndex(term_count: i32) usize` — term_count % PARTITION_COUNT
- `nextPartitionIndex(current: usize) usize` — (current + 1) % PARTITION_COUNT

`LogBuffer` struct:
- `init(allocator, term_length: i32) !LogBuffer` — allocate mmap or heap-backed buffer
- `deinit(allocator)` — release
- `termBuffer(partition: usize) []u8`
- `metaData() *LogBufferMetadata`

Unit tests: rotation arithmetic, partition index wrapping.

Reference: `aeron-client/src/main/java/io/aeron/logbuffer/LogBufferDescriptor.java`

---

### Task P1-3: Term Appender (depends on P1-2)

**File**: `src/logbuffer/term_appender.zig`

Append frames to a single term partition with atomic tail advancement.

`TermAppender` struct:
- `appendData(header: DataHeader, payload: []const u8) AppendResult` — claim tail space atomically, write header + payload
- `appendPadding(header: DataHeader, padding_length: i32) AppendResult` — fill gap with padding frame
- `packTail(term_id: i32, term_offset: i32) i64` — encode raw tail
- `rawTailVolatile() i64` — atomic load

`AppendResult`:
- `ok(term_offset: i32)` — success, returns offset where data was written
- `tripped` — term is full, rotate needed
- `admin_action` — CAS failure, retry
- `padding_applied` — padding frame written at end, retry in next term

Locking strategy: CAS on raw_tail (compare-and-swap). No mutex. Must be correct for concurrent publishers.

Unit tests: single append, multi-append filling a term, padding insertion on alignment gap.

Reference: `aeron-client/src/main/java/io/aeron/logbuffer/TermAppender.java`

---

### Task P1-4: Term Reader (depends on P1-2)

**File**: `src/logbuffer/term_reader.zig`

Read frames forward from a term partition.

```zig
pub const FragmentHandler = *const fn (header: *const DataHeader, buffer: []const u8, ctx: *anyopaque) void;
```

`TermReader` struct:
- `read(term: []const u8, offset: i32, handler: FragmentHandler, ctx: *anyopaque, fragments_limit: i32) ReadResult` — scan forward, skip padding, call handler for DATA frames
- stops when: fragments_limit reached, end of committed data (frame_length == 0), or term end

`ReadResult`:
- `fragments_read: i32`
- `offset: i32` — position after last read frame

Unit tests: read single frame, read multiple frames, stop on padding, stop at limit.

Reference: `aeron-client/src/main/java/io/aeron/logbuffer/TermReader.java`

---

### Task P1-5: IPC Ring Buffer (no deps)

**File**: `src/ipc/ring_buffer.zig`

Lock-free many-to-one ring buffer. Used for client→driver command IPC.

Constants:
- `RECORD_ALIGNMENT = 8`
- `HEADER_LENGTH = 8` (msg_type_id: i32 + record_length: i32)
- `TAIL_POSITION_OFFSET`, `HEAD_POSITION_OFFSET`, `HEAD_CACHE_POSITION_OFFSET` — metadata offsets at end of buffer

`ManyToOneRingBuffer` struct (backed by `[]u8` — last 128 bytes are metadata):
- `write(msg_type_id: i32, data: []const u8) bool` — claim space, write record, advance tail atomically
- `read(handler: MessageHandler, message_count_limit: i32) i32` — consume from head
- `nextCorrelationId() i64` — atomic fetch-add on dedicated counter slot

`MessageHandler`:
```zig
pub const MessageHandler = *const fn (msg_type_id: i32, data: []const u8, ctx: *anyopaque) void;
```

Padding record (`PADDING_MSG_TYPE_ID = -1`) inserted when record won't fit at tail end.

Unit tests: single write/read, concurrent writes (can use single thread CAS test), wrap-around, padding insertion.

Reference: `aeron-driver/src/main/java/org/agrona/concurrent/ringbuffer/ManyToOneRingBuffer.java`

---

### Task P1-6: Broadcast Transmitter / Receiver (no deps)

**File**: `src/ipc/broadcast.zig`

One-writer-many-reader broadcast buffer. Used for driver→client notifications.

`BroadcastTransmitter` struct:
- `transmit(msg_type_id: i32, data: []const u8) void` — write record, bump cursor

`BroadcastReceiver` struct:
- `receiveNext() bool` — advance to next record if available
- `typeId() i32`
- `buffer() []const u8`
- `offset() i32`
- `length() i32`
- `lapped() bool` — detect if transmitter has overrun us

Unit tests: transmit + receive, lapping detection.

Reference: `aeron-driver/src/main/java/org/agrona/concurrent/broadcast/`

---

### Task P1-7: Counters Map (no deps)

**File**: `src/ipc/counters.zig`

Shared-memory counters for position tracking and metrics.

Counter types (label + value pairs):
- `PUBLISHER_LIMIT`
- `SENDER_POSITION`
- `RECEIVER_HWM`
- `SUBSCRIBER_POSITION`
- `CHANNEL_STATUS`

`CountersMap` struct (backed by two `[]u8` — meta region + values region):
- `allocate(type_id: i32, label: []const u8) CounterHandle`
- `free(counter_id: i32) void`
- `get(counter_id: i32) i64` — volatile read
- `set(counter_id: i32, value: i64) void` — volatile write
- `addOrdered(counter_id: i32, delta: i64) void` — atomic fetch-add
- `compareAndSet(counter_id: i32, expected: i64, update: i64) bool`

Unit tests: allocate, set/get, atomic add, free + reuse.

Reference: `aeron-driver/src/main/java/org/agrona/concurrent/status/CountersMap.java`

---

### Task P1-8: UDP Channel & Transport (no deps)

**File**: `src/transport/udp_channel.zig`, `src/transport/endpoint.zig`, `src/transport/poller.zig`

UDP socket layer for both unicast and multicast.

`UdpChannel`:
- Parse Aeron URI: `aeron:udp?endpoint=localhost:40123`, `aeron:udp?endpoint=224.0.1.1:40456|interface=eth0`
- `isMulticast() bool`
- `localAddress() std.net.Address`
- `remoteAddress() std.net.Address`

`SendChannelEndpoint`:
- `open(allocator, channel: UdpChannel) !SendChannelEndpoint`
- `send(dest: std.net.Address, data: []const u8) !usize`
- `close() void`

`ReceiveChannelEndpoint`:
- `open(allocator, channel: UdpChannel) !ReceiveChannelEndpoint`
- `bind() !void`
- `joinMulticast(group: std.net.Address) !void`
- `recv(buf: []u8, src: *std.net.Address) !usize`
- `close() void`

`Poller` (using `std.posix.poll`):
- `add(fd: std.posix.fd_t, endpoint: *ReceiveChannelEndpoint) void`
- `remove(fd: std.posix.fd_t) void`
- `poll(timeout_ms: i32) i32` — returns number of ready fds, dispatches recv to endpoints

Unit tests: parse Aeron URI (unicast + multicast), open/close socket (test-only bind to ephemeral port).

---

### Task P1-9: Sender Agent (depends on P1-1, P1-2, P1-3, P1-8)

**File**: `src/driver/sender.zig`

Sender duty agent — hot loop that reads from publication log buffers and sends UDP frames.

`Sender` struct:
- `doWork() i32` — single duty cycle, returns work count
  - For each active publication:
    - Read unsent frames from log buffer (from senderPosition to publisherLimit)
    - Send DATA frames via SendChannelEndpoint
    - Send SETUP frames on new/retransmit
    - Advance senderPosition counter
  - Check retransmit queue: send NAK-requested retransmits
- `onAddPublication(pub: *NetworkPublication) void`
- `onRemovePublication(session_id: i32, stream_id: i32) void`
- `onRetransmit(session_id: i32, stream_id: i32, term_id: i32, term_offset: i32, length: i32) void`

`NetworkPublication` struct:
- `session_id`, `stream_id`, `initial_term_id`
- `log_buffer: *LogBuffer`
- `sender_position: CounterHandle`
- `publisher_limit: CounterHandle`
- `send_channel: *SendChannelEndpoint`
- `mtu: i32`

Unit tests: mock send endpoint, verify DATA frame bytes, test SETUP retransmit interval.

Reference: `aeron-driver/src/main/java/io/aeron/driver/Sender.java`

---

### Task P1-10: Receiver Agent (depends on P1-1, P1-2, P1-8)

**File**: `src/driver/receiver.zig`

Receiver duty agent — processes incoming UDP frames.

`Receiver` struct:
- `doWork() i32` — single duty cycle
  - Poll all ReceiveChannelEndpoints
  - Dispatch frames by type:
    - `DATA` → write to subscriber log buffer via Image
    - `SETUP` → create Image if new session, send STATUS
    - `RTT_MEASUREMENT` → echo reply
- `onAddSubscription(endpoint: *ReceiveChannelEndpoint) void`
- `onRemoveSubscription(...) void`
- `sendNak(image: *Image, term_id: i32, term_offset: i32, length: i32) void`
- `sendStatus(image: *Image) void`

`Image` struct (per sender-session per subscription):
- `session_id`, `stream_id`, `term_length`, `mtu`
- `log_buffer: *LogBuffer`
- `receiver_hwm: CounterHandle` — highest term_offset seen
- `subscriber_position: CounterHandle` — where subscriber has consumed to
- `rebuildPosition` — gap-tracking

Gap tracking:
- Maintain gap scanner: if received offset > expected, enqueue NAK
- NAK timer: coalesce and delay NAKs (don't flood sender)

Unit tests: inject DATA frame bytes, verify log buffer write, verify gap detection + NAK.

Reference: `aeron-driver/src/main/java/io/aeron/driver/Receiver.java`

---

### Task P1-11: Driver Conductor (depends on P1-5, P1-6, P1-7)

**File**: `src/driver/conductor.zig`

DriverConductor — processes client IPC commands and manages all driver resources.

`DriverConductor` struct:
- `doWork() i32` — single duty cycle
  - Read from client ring buffer (commands)
  - Process commands:
    - `ADD_PUBLICATION` → create NetworkPublication, map log buffer, notify client
    - `REMOVE_PUBLICATION` → decrement refcount, clean up on zero
    - `ADD_SUBSCRIPTION` → create Subscription, create ReceiveChannelEndpoint if needed
    - `REMOVE_SUBSCRIPTION` → clean up
    - `CLIENT_KEEPALIVE` → update client liveness timer
    - `ADD_COUNTER` / `REMOVE_COUNTER` → delegate to CountersMap
  - Check liveness of all clients (evict if timed out)
  - Send responses via BroadcastTransmitter:
    - `ON_PUBLICATION_READY` — log file path, session_id
    - `ON_SUBSCRIPTION_READY` — subscription_id
    - `ON_ERROR` — error code + message
    - `ON_IMAGE_READY` / `ON_IMAGE_CLOSE`

Resource lifecycle:
- Publications are reference-counted (multiple clients can hold same session)
- Subscriptions matched to Images by (session_id, stream_id, endpoint)
- LogBuffer files created in `aeron.dir` (default `/dev/shm/aeron-<uid>`)

Unit tests: mock ring buffer, verify correct response messages, lifecycle round-trips.

Reference: `aeron-driver/src/main/java/io/aeron/driver/DriverConductor.java`

---

### Task P1-12: Media Driver Orchestrator (depends on P1-9, P1-10, P1-11)

**File**: `src/driver/media_driver.zig`, `src/main.zig`

Top-level MediaDriver that owns all agents and runs their duty cycles.

`MediaDriverContext` — all configuration:
- `aeron_dir: []const u8` — default `/dev/shm/aeron-<uid>`
- `term_buffer_length: i32` — default 16MB
- `ipc_term_buffer_length: i32` — default 64KB
- `mtu_length: i32` — default 1408
- `client_liveness_timeout_ns: i64` — default 5s
- `publication_connection_timeout_ns: i64` — default 5s

`MediaDriver` struct:
- `init(allocator, ctx: MediaDriverContext) !MediaDriver`
- `deinit() void`
- `start() !void` — start conductor/sender/receiver threads (or inline for embedded)
- `close() void`

Two modes:
- **Standalone** (default): each agent runs in its own OS thread with busy-spin
- **Embedded**: caller drives duty cycles manually (for testing)

`main.zig` CLI args:
- `-Daeron.dir=PATH`
- `-Daeron.term.buffer.length=N`

Integration test: start embedded driver, create Publication + Subscription in same process, send 100 messages, verify all received. Assert no gaps.

Reference: `aeron-driver/src/main/java/io/aeron/driver/MediaDriver.java`

---

### Task P1-13: Client Library (depends on P1-5, P1-6, P1-7)

**File**: `src/aeron.zig`, `src/publication.zig`, `src/subscription.zig`, `src/image.zig`

Client library — the API users call to create publications and subscriptions.

`Aeron` context:
- `init(allocator, ctx: AeronContext) !Aeron` — connect to driver via ring buffer + broadcast
- `deinit() void`
- `addPublication(channel: []const u8, stream_id: i32) !*Publication`
- `addSubscription(channel: []const u8, stream_id: i32) !*Subscription`
- `doWork() i32` — poll conductor responses

`AeronContext`:
- `aeron_dir: []const u8`

`ExclusivePublication`:
- `offer(data: []const u8) OfferResult` — write to log buffer via TermAppender
- `offerParts(iov: []const IoVec) OfferResult` — vectored write (for header + payload)
- `isConnected() bool` — check sender position counter
- `close() void`

`OfferResult`:
- `ok(position: i64)` — new stream position
- `back_pressure` — publisher limit reached
- `not_connected` — no active subscribers
- `admin_action` — retry
- `closed`
- `max_position_exceeded`

`Subscription`:
- `poll(handler: FragmentHandler, fragment_limit: i32) i32`
- `images() []*Image`
- `isConnected() bool`
- `close() void`

`Image`:
- `poll(handler: FragmentHandler, fragment_limit: i32) i32` — delegate to TermReader
- `position() i64`
- `isEndOfStream() bool`
- `close() void`

Unit tests: mock driver IPC, verify publication offer writes correct bytes to log buffer, subscription poll invokes handler correctly.

Reference: `aeron-client/src/main/java/io/aeron/Aeron.java`

---

### Task P1-14: Integration Tests (depends on P1-12, P1-13)

**File**: `test/integration_test.zig`, `test/harness.zig`

End-to-end tests that spin up our embedded MediaDriver and verify wire compatibility.

`TestHarness`:
- Start embedded MediaDriver
- Create Aeron client context connected to same driver
- Helpers: `createPub`, `createSub`, `sendMessages(n)`, `pollMessages(n, timeout_ms)`, `assertNoGaps()`

Test cases:
1. **Basic round-trip**: 1 publisher, 1 subscriber, 1 stream, 1000 messages, verify all received in order
2. **Back-pressure**: publisher at limit, verify `back_pressure` result, verify eventually clears
3. **Multiple streams**: 3 publishers on different stream_ids, 3 subscribers, no cross-contamination
4. **Fragmentation**: message larger than MTU (1408 bytes), verify reassembly (BEGIN/END flags)
5. **Publisher disconnect**: publisher closes, subscriber sees EOS
6. **Subscriber catch-up**: subscriber starts after 100 messages sent, verify positions reconcile

Interop test (requires docker / real Java driver — optional, gate on env flag):
7. **Interop-pub**: our driver publishes, Java Aeron BasicSubscriber receives
8. **Interop-sub**: Java Aeron BasicPublisher sends, our driver subscribes

Reference: `aeron-samples/src/main/java/io/aeron/samples/`

---

## Phase 2 — Aeron Archive

Goal: persistent recording and replay of Aeron streams. Wire-compatible with Java `AeronArchive` client.

Prerequisites: Phase 1 complete.

Reference: `aeron-archive/src/main/java/io/aeron/archive/`

---

### Task P2-1: Archive Protocol Codec (no deps within phase)

**File**: `src/archive/protocol.zig`

Archive control protocol frames (SBE-encoded in real Aeron; we use a simplified struct layout).

Commands (client→archive):
- `StartRecordingRequest` — channel, stream_id, source_location
- `StopRecordingRequest` — channel, stream_id
- `ReplayRequest` — recording_id, position, length, replay_channel, replay_stream_id
- `StopReplayRequest` — replay_session_id
- `ListRecordingsRequest` — from_recording_id, record_count
- `ExtendRecordingRequest`

Responses (archive→client):
- `RecordingStarted` — recording_id
- `RecordingProgress` — recording_id, start_position, stop_position
- `RecordingDescriptor` — full recording metadata
- `ControlResponse` — correlation_id, code, error_message

Catalog entry:
- `RecordingDescriptorDecoder` — recording_id, start_timestamp, stop_timestamp, start_position, stop_position, session_id, stream_id, channel, source_identity

---

### Task P2-2: Recording Catalog (no deps within phase)

**File**: `src/archive/catalog.zig`

Persistent catalog mapping `recording_id → RecordingDescriptor`.

Backed by a flat binary file: `archive/catalog.dat`

`Catalog` struct:
- `open(allocator, path: []const u8) !Catalog`
- `close() void`
- `addNewRecording(...) i64` — returns recording_id
- `updateStopPosition(recording_id: i64, stop_position: i64) void`
- `updateStopTimestamp(recording_id: i64, stop_timestamp: i64) void`
- `recordingDescriptor(recording_id: i64) ?RecordingDescriptorDecoder`
- `listRecordings(from_id: i64, count: i32, handler: ListRecordingsHandler) i32`
- `findLastMatchingRecording(min_id: i64, channel: []const u8, stream_id: i32) ?i64`

File format: fixed-size records (1024 bytes each), sequential write, mmap for reads.

Unit tests: add 100 recordings, lookup by ID, list range, find by channel+stream.

---

### Task P2-3: Recorder (depends on P2-2)

**File**: `src/archive/recorder.zig`

`RecordingSession` — subscribes to a channel/stream, writes incoming fragment data to recording file.

`RecordingWriter`:
- Each recording gets a file: `archive/<recording_id>.dat`
- Write raw log buffer segments sequentially
- Flush and sync on rotation (term boundary)
- Track `startPosition`, `stopPosition`

`Recorder` duty agent:
- `onStartRecording(request) !void` — create Subscription, create RecordingSession
- `onStopRecording(request) void` — close RecordingSession, update catalog stop_position
- `doWork() i32` — poll active RecordingSessions (call `sub.poll(handler, limit)`)

---

### Task P2-4: Replayer (depends on P2-2)

**File**: `src/archive/replayer.zig`

`ReplaySession` — reads a recording file and sends it as a live Aeron stream.

`ReplaySession` struct:
- Open recording file at `start_position`
- Create ExclusivePublication on `replay_channel:replay_stream_id`
- Read frames from file, offer to publication at configured speed (null = as fast as possible)
- Send `RecordingProgress` responses
- Detect EOS, send final progress, close publication

`Replayer` duty agent:
- `onReplayRequest(request) !void` — create ReplaySession
- `onStopReplay(request) void` — close session
- `doWork() i32` — advance all active ReplaySessions

---

### Task P2-5: Archive Conductor (depends on P2-1, P2-3, P2-4)

**File**: `src/archive/conductor.zig`

Processes control commands from `AeronArchive` clients via a dedicated Aeron stream
(`aeron:udp?endpoint=localhost:8010` by default).

Command loop:
- Subscribe to archive control channel
- Decode command from log buffer
- Route to Recorder or Replayer
- Send response via reply channel (per-request correlation_id)

Authentication stub: always allow (real Aeron has challenge/response).

---

### Task P2-6: Archive Context + Main (depends on P2-5)

**File**: `src/archive/archive.zig`, `src/archive/main.zig`

`ArchiveContext` — configuration:
- `control_channel` / `control_stream_id`
- `recording_events_channel` / `recording_events_stream_id`
- `archive_dir: []const u8`
- `segment_file_length: i64` (default 128MB)

`Archive` struct — owns conductor + replayer + recorder, runs duty cycles.

Standalone binary: `zig-out/bin/aeron-archive`

Integration test: start embedded driver + archive, record a 10k-message publication,
replay from position 0, verify all messages received.

---

## Phase 3 — Aeron Cluster

Goal: Raft-based consensus for state machine replication. Wire-compatible with Java `AeronCluster` client.

Prerequisites: Phase 1 + Phase 2 complete. Archive used for Raft log persistence.

Reference: `aeron-cluster/src/main/java/io/aeron/cluster/`

---

### Task P3-1: Cluster Protocol Codec (no deps within phase)

**File**: `src/cluster/protocol.zig`

Cluster session and consensus protocol messages:

Client-facing:
- `SessionConnectRequest` — cluster_session_id, challenge_payload
- `SessionCloseRequest`
- `SessionMessageHeader` — cluster_session_id, timestamp, correlation_id

Cluster-internal (consensus):
- `AppendRequestHeader` — leader_ship_term_id, log_position, timestamp, leader_member_id
- `AppendPositionHeader` — follower acknowledgement
- `CommitPositionHeader` — leader broadcast of committed position
- `RequestVoteHeader` — Raft vote request
- `VoteHeader` — Raft vote response
- `NewLeadershipTermHeader` — term transition notification

Service-facing:
- `ServiceAck` — service_id + log_position + timestamp

---

### Task P3-2: Raft Election (no deps within phase)

**File**: `src/cluster/election.zig`

Raft leader election state machine.

States: `INIT → CANVASS → CANDIDATE_BALLOT → FOLLOWER_BALLOT → LEADER_LOG_REPLICATION → LEADER_READY → FOLLOWER_READY`

`Election` struct:
- `doWork(now_ns: i64) i32`
- `onRequestVote(from_member: i32, log_leader_term_id: i64, log_position: i64, candidate_term_id: i64) void`
- `onVote(candidate_term_id: i64, log_leader_term_id: i64, log_position: i64, candidate_member_id: i32, follower_member_id: i32, vote: bool) void`
- `onNewLeadershipTerm(...) void`
- `onCanvassPosition(log_leader_term_id: i64, log_position: i64, follower_member_id: i32) void`

Quorum math: `(cluster_size / 2) + 1`

Timers: `electionTimeout`, `startupCanvassTimeout`, `leaderHeartbeatTimeout`

Unit tests: 3-node election simulation, quorum calculation, vote rejection for stale term.

Reference: `aeron-cluster/src/main/java/io/aeron/cluster/Election.java`

---

### Task P3-3: Log Replication (depends on P3-2)

**File**: `src/cluster/log.zig`

Leader appends log entries; followers replicate via Aeron unicast streams.

`ClusterLog`:
- `append(encoded_msg: []const u8) i64` — returns log_position
- `commitPosition() i64`
- `appendPosition() i64`

`LogFollower` (follower side):
- Subscribes to leader's log channel
- Receives `AppendRequest`, writes to local log
- Sends `AppendPosition` ACK
- On commit: apply to service

`LogLeader`:
- Tracks `AppendPosition` from each follower
- Advances `commitPosition` when quorum reached
- Broadcasts `CommitPosition`

Integration with Archive: log segments are Archive recordings for persistence.

---

### Task P3-4: Cluster Conductor (depends on P3-2, P3-3)

**File**: `src/cluster/conductor.zig`

Cluster node conductor — handles client sessions and service protocol.

Client ingress:
- Accept `SessionConnectRequest` from clients (via ingress channel)
- Route messages to current leader (redirect if follower)
- Manage session timeouts

Service interface:
- Deliver committed log entries to registered `ClusteredService`
- Receive `ServiceAck` from service
- Take snapshots: request service to write state to Archive

Timer service:
- Schedule timers in cluster time (not wall clock) for deterministic replay

---

### Task P3-5: Cluster Context + Main (depends on P3-4)

**File**: `src/cluster/cluster.zig`, `src/cluster/main.zig`

`ClusterContext` — configuration:
- `cluster_members: []const MemberConfig` — id, host, ports
- `member_id: i32`
- `ingress_channel` / `ingress_stream_id`
- `log_channel` / `log_stream_id`
- `consensus_channel` / `consensus_stream_id`
- `snapshot_counter`
- `archive_context: ArchiveContext`

`ConsensusModule` struct — owns election + log + conductor.

Standalone binary: `zig-out/bin/aeron-cluster-node`

Integration test: 3-node cluster (3 threads / 3 embedded drivers), leader elected, 1000 messages ingressed,
kill leader, new election completes, messages still committed correctly.

---

## Phase 4 — Polish & Observability

These tasks can begin after Phase 1 is complete and run in parallel with Phases 2/3.

### Task P4-1: Aeron URI Parser (no deps)

Full Aeron URI parsing: `aeron:udp?endpoint=...`, `aeron:ipc`, `aeron:udp?control=...|control-mode=dynamic`

Parameters: `endpoint`, `control`, `control-mode`, `interface`, `ttl`, `mtu`, `term-length`, `sparse`

### Task P4-2: Loss Report

**File**: `src/loss_report.zig`

Shared memory mapped loss report file. Write an entry per gap detected by Receiver.
External tools (like `LossStat`) can mmap this file to display live loss stats.

### Task P4-3: Driver Events Log

**File**: `src/event_log.zig`

Ring-buffer-backed event log for debug/trace. Events: FRAME_IN, FRAME_OUT, CMD_IN, CMD_OUT, etc.
External tools mmap and display. Enabled at compile time via `-Devent_log=true`.

### Task P4-4: Error Handler & Counters Reporting

Expose key system counters: bytes_sent, bytes_received, nak_sent, nak_received, errors, heartbeats.
Format as a text table readable via `make counters`.

---

## Phase 5 — Parity Completion

Goal: close the remaining gap to upstream Aeron by tightening protocol breadth, cluster recovery, archive fidelity, and benchmark/interop automation.

Key reference files in the upstream repo:
- `aeron-driver/src/main/java/io/aeron/driver/`
- `aeron-archive/src/main/java/io/aeron/archive/`
- `aeron-cluster/src/main/java/io/aeron/cluster/`
- `aeron-all` sample apps and interop harnesses

---

### Task P5-1: Protocol Breadth and Codec Parity

**File**: `src/protocol/`, `src/transport/`

Expand the protocol surface to cover the remaining Aeron-compatible message shapes and URI forms that the current stack still treats as simplified.

Implement:
- the remaining transport/control codec variants needed by current archive and cluster flows
- stricter URI parsing for Aeron-compatible channel forms used by upstream samples
- unit tests for every new codec branch and parser edge case

Acceptance criteria:
- `make test-unit`
- `make check`

Dependencies:
- Phase 1 frame and transport foundations

---

### Task P5-2: Cluster Failure and Rejoin Correctness

**File**: `src/cluster/`, `test/integration/`

Make the cluster stack survive leader loss, follower catch-up, and replay/rejoin without relying on the simplified happy-path assumptions.

Implement:
- leader/follower handoff checks that preserve log progress
- recovery-oriented tests for election restart, commit advancement, and session redirection
- a 3-node integration scenario that kills the leader and verifies a new leader can continue processing

Acceptance criteria:
- `make test-unit`
- `make test-integration`
- `make check`

Dependencies:
- Task P5-1

---

### Task P5-3: Archive Restart and Catalog Fidelity

**File**: `src/archive/`, `docs/tutorial/05-archive/`

Bring archive behavior closer to upstream by making restart, catalog, and replay behavior more faithful and less ad hoc.

Implement:
- recording descriptor fields that still use placeholder values
- segment rotation and replay behavior that can survive archive restart
- archive control tests that verify list/replay/stop flows against persisted data
- a tutorial chapter for the parity behavior if the course material needs to stay in sync

Acceptance criteria:
- `make test-unit`
- `make check`

Dependencies:
- Task P5-1

---

### Task P5-4: Interop Matrix Automation

**File**: `Makefile`, `deploy/interop/`, `test/interop/`

Make the interop path self-contained and explicit so a fresh clone can bring up the same matrix without manual artifact handling.

Implement:
- a pinned, deterministic fetch path for the Java Aeron JAR
- explicit Java-publisher/Zig-subscriber and Zig-publisher/Java-subscriber jobs in the interop overlay
- a single make target that performs setup, image build, and job execution

Acceptance criteria:
- `make setup`
- `make interop`

Dependencies:
- Task P5-1

---

### Task P5-5: Throughput Baseline and Perf Hygiene

**File**: `examples/throughput.zig`, `src/bench/throughput.zig`, `Makefile`

Turn the current throughput helper into a useful benchmark entrypoint and use it to watch for regressions as the protocol and cluster work land.

Implement:
- a real `throughput` wrapper that invokes the built benchmark or example
- benchmark documentation that explains the expected use
- a small baseline run or smoke check that can be used before larger protocol changes

Acceptance criteria:
- `make bench`
- `make check`

Dependencies:
- Task P5-1

---

### Suggested Sequence

1. P5-1 protocol breadth and codec parity.
2. P5-4 interop matrix automation.
3. P5-3 archive restart and catalog fidelity.
4. P5-2 cluster failure and rejoin correctness.
5. P5-5 throughput baseline and perf hygiene.

This order removes the broad compatibility blockers first, then uses interop and archive coverage to validate the transport path before the more stateful cluster recovery work.

---

## Dependency Graph Summary

```
P1-1 (frame codec)    ──────────────────────────────────────┐
P1-2 (log buffer)     ─── P1-3 (term appender) ─────────────┤
                      └── P1-4 (term reader)   ─────────────┤
P1-5 (ring buffer)    ──────────────────────────────────────┤
P1-6 (broadcast)      ──────────────────────────────────────┤→ P1-11 (conductor) ─┐
P1-7 (counters)       ──────────────────────────────────────┘                      │
P1-8 (UDP channel)    ─── P1-9 (sender) ────────────────────────────────────────┐  │
                      └── P1-10 (receiver) ─────────────────────────────────────┤  │
                                                                                  ↓  ↓
                                                                       P1-12 (media driver)
                                                                            ↑
P1-5,6,7 ────────────────────────────────────────────────→ P1-13 (client lib)
                                                                            ↓
                                                                   P1-14 (integration tests)

Phase 2 (Archive) requires all of Phase 1
Phase 3 (Cluster) requires Phase 1 + Phase 2
Phase 4 tasks: P4-1 standalone; P4-2,3,4 need Phase 1
```

## Agent Execution Notes

- Tasks with `(no deps)` label can be started in parallel immediately
- Each task should result in a passing `make test` for its module
- Use `make check` before marking any task done
- Keep `docs/todo.md` updated as tasks complete
- Cross-reference https://github.com/aeron-io/aeron for any protocol detail questions
