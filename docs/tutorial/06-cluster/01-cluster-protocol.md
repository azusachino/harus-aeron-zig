# 6.1 Cluster Protocol

Aeron is a fire-and-forget system by design — but many applications need stronger guarantees. Financial transactions, order books, and event-sourced systems need to know that a message was not only published but **replicated to a majority of nodes** before the service processes it.

Aeron Cluster solves this with **Raft consensus**: a time-tested algorithm that coordinates multiple nodes to maintain a single, consistent log of committed entries. Every message is replicated across the cluster before the leader tells the service "it's safe to process this."

In this chapter, you'll learn the wire-level protocol that makes this happen — a set of fixed-size binary messages that divide cluster communication into three families: **client-facing**, **consensus**, and **service notifications**.

## What You'll Build

By the end of this chapter, you'll understand:
- Why every Raft struct uses `extern struct` with explicit `_padding` fields
- The full message taxonomy: client (201–204), consensus (211–216), service (221)
- How type IDs route messages in the cluster conductor
- Session event codes and when each fires

## Why It Works This Way (Aeron Concept)

Real Aeron's cluster implementation (C++ driver + Java client) uses **Simple Binary Encoding (SBE)**, a schema-less codec where every message is either:
1. A fixed-size header that describes its own size
2. Followed by optional variable-length fields (like channel strings)

All cluster messages are transmitted over **Aeron Publications and Subscriptions** — the same shared-memory ring buffers and multicast channels used by regular clients. This means:
- A cluster node is also an Aeron client (it publishes and subscribes like any other app)
- Election messages go on the consensus channel; log replication on the log channel; client ingress on the ingress channel
- The same fragmentation, flow control, and NAK logic applies to cluster messages as to application messages

### Message Families

Cluster message types are organized by range:

| Family | MSG_TYPE_ID | Direction | Purpose |
|--------|-----------|-----------|---------|
| **Client** | 201–204 | Bidirectional | Session lifecycle and client-to-cluster routing |
| **Consensus** | 211–216 | Node-to-node | Raft election and log replication |
| **Service** | 221–230 | Internal | Deliver committed entries to application service |

Each family serves a distinct layer:

**Client messages** let your application talk to the cluster:
- `SessionConnectRequest` (201): "I want a session, here's my response channel"
- `SessionCloseRequest` (202): "Close my session"
- `SessionMessage` (203): "Process this message on the leader"
- `SessionEvent` (204): Server tells client "your session is OK / error / redirect"

**Consensus messages** coordinate the Raft algorithm between nodes:
- `RequestVote` (214): "I'm a candidate, vote for me"
- `Vote` (215): "You have my vote (or not)"
- `AppendRequest` (211): "Here are new log entries"
- `AppendPosition` (212): "I've written these entries"
- `CommitPosition` (213): "A quorum has these entries, it's safe"
- `NewLeadershipTerm` (216): "I'm the new leader"

**Service messages** are internal — they deliver committed entries to your application layer.

## Zig Concept: `extern struct` with Explicit `_padding` Fields

In Zig, we match the C ABI exactly with `extern struct`. But cluster structs have a subtle alignment requirement: all 64-bit fields (like `leader_ship_term_id: i64`) must be 8-byte aligned for atomic operations and cache-line locality.

### The Pattern

Consider the simplest case: a message with three 64-bit fields and one 32-bit field.

```zig
pub const BadAlignment = extern struct {
    term_id: i64,        // bytes 0–7
    position: i64,       // bytes 8–15
    member_id: i32,      // bytes 16–19 (NOT 8-byte aligned!)
};
```

This works (C compilers pad it), but the `member_id` at offset 16 is only 4-byte aligned. On some architectures, atomic loads of the next 64-bit field would fail.

The fix is explicit:

```zig
pub const GoodAlignment = extern struct {
    term_id: i64,        // bytes 0–7
    position: i64,       // bytes 8–15
    member_id: i32,      // bytes 16–19
    _padding: i32 = 0,   // bytes 20–23 (explicit filler)
};

comptime {
    std.debug.assert(@sizeOf(GoodAlignment) == 24);
    std.debug.assert(@alignOf(GoodAlignment) == 8);
}
```

Notice the `= 0` default for `_padding`. This means you can construct the struct without specifying it; Zig fills in the zero. This is why:
- **Predictable layout**: every compiler sees identical byte offsets
- **Shared memory safety**: if the log buffer mmap'd on another node expects 24 bytes, we deliver exactly 24
- **Wire compatibility**: language-agnostic; a Java or C++ node can parse our messages without surprises

### Standalone Example: Custom Alignment

Here's a Zig-specific example before we get to Aeron:

```zig
const std = @import("std");

pub fn main() void {
    // Without explicit padding, the compiler inserts it invisibly
    const Implicit = extern struct {
        a: i64,
        b: i32,
    };

    // With explicit padding, we control it
    const Explicit = extern struct {
        a: i64,
        b: i32,
        _pad: i32 = 0,
    };

    std.debug.print("Implicit size: {}\n", .{@sizeOf(Implicit)});    // 16
    std.debug.print("Explicit size: {}\n", .{@sizeOf(Explicit)});    // 16
    std.debug.print("Both match, but Explicit is clearer.\n", .{});
}
```

Both structs end up 16 bytes. But with `Explicit`, anyone reading the code knows the padding is intentional, not accidental. In a cluster protocol, this clarity prevents subtle bugs when protocol specs change.

## The Code

Open `src/cluster/protocol.zig`. Here are the three families:

### Client Messages

```zig
/// SessionConnectRequest — client initiates cluster session connection
pub const SessionConnectRequest = extern struct {
    correlation_id: i64,           // Opaque ID the client provides; echoed in SessionEvent
    cluster_session_id: i64,       // Assigned by the leader; 0 if not yet connected
    response_stream_id: i32,       // Aeron stream ID where server sends SessionEvent
    response_channel_length: i32,  // Length of response_channel string (follows in buffer)
    // Variable-length response_channel follows in the buffer

    pub const HEADER_LENGTH = @sizeOf(SessionConnectRequest);
    pub const MSG_TYPE_ID: i32 = 201;
};

/// SessionEvent — notification of session state changes
pub const SessionEvent = extern struct {
    cluster_session_id: i64,
    correlation_id: i64,
    leader_ship_term_id: i64,
    leader_member_id: i32,
    event_code: i32,              // One of EventCode enum

    pub const HEADER_LENGTH = @sizeOf(SessionEvent);
    pub const MSG_TYPE_ID: i32 = 204;
};

pub const EventCode = enum(i32) {
    ok = 0,                       // Session established
    error_val = 1,                // Generic error
    redirect = 2,                 // Go to leader_member_id instead
    authentication_rejected = 3,  // Auth failed
};
```

### Consensus Messages

```zig
/// AppendRequestHeader — leader sends log entries to followers
pub const AppendRequestHeader = extern struct {
    leader_ship_term_id: i64,  // Raft term; must match follower's current term
    log_position: i64,         // Starting byte offset in leader's log
    timestamp: i64,            // When leader created this append
    leader_member_id: i32,     // Identifies the sender
    _padding: i32 = 0,         // Explicit padding to 8-byte alignment

    pub const HEADER_LENGTH = @sizeOf(AppendRequestHeader);
    pub const MSG_TYPE_ID: i32 = 211;
};

/// AppendPositionHeader — follower acknowledges append progress
pub const AppendPositionHeader = extern struct {
    leader_ship_term_id: i64,  // Echoes the append request's term
    log_position: i64,         // "I've written entries up to this byte offset"
    follower_member_id: i32,   // Who am I?
    _padding: i32 = 0,

    pub const HEADER_LENGTH = @sizeOf(AppendPositionHeader);
    pub const MSG_TYPE_ID: i32 = 212;
};

/// CommitPositionHeader — leader broadcasts committed log position
pub const CommitPositionHeader = extern struct {
    leader_ship_term_id: i64,
    log_position: i64,         // "A quorum has this position; service can process it"
    leader_member_id: i32,
    _padding: i32 = 0,

    pub const HEADER_LENGTH = @sizeOf(CommitPositionHeader);
    pub const MSG_TYPE_ID: i32 = 213;
};

/// RequestVoteHeader — candidate requests votes during election
pub const RequestVoteHeader = extern struct {
    log_leader_ship_term_id: i64,  // Latest leadership term the candidate knows
    log_position: i64,              // Latest log position the candidate knows
    candidate_term_id: i64,         // Term the candidate is voting in
    candidate_member_id: i32,       // Who's asking?
    _padding: i32 = 0,

    pub const HEADER_LENGTH = @sizeOf(RequestVoteHeader);
    pub const MSG_TYPE_ID: i32 = 214;
};

/// VoteHeader — member votes in election
pub const VoteHeader = extern struct {
    candidate_term_id: i64,
    log_leader_ship_term_id: i64,
    log_position: i64,
    candidate_member_id: i32,       // Who am I voting for?
    follower_member_id: i32,        // Who am I?
    vote: i32,                      // 1 = granted, 0 = denied
    _padding: i32 = 0,

    pub const HEADER_LENGTH = @sizeOf(VoteHeader);
    pub const MSG_TYPE_ID: i32 = 215;
};
```

Look closely at `AppendRequestHeader`:
- Three `i64` fields (24 bytes)
- One `i32` field (4 bytes)
- One explicit `_padding: i32` (4 bytes)
- **Total: 32 bytes**, all 8-byte aligned

If you remove the `_padding` line, Zig still pads it (the compiler is allowed to), but the code is ambiguous. With explicit padding, anyone who reads this code sees: "I'm routing this across shared memory, and I need that alignment."

### Comptime Assertions

The best practice is to add assertions:

```zig
comptime {
    std.debug.assert(@sizeOf(AppendRequestHeader) == 32);
    std.debug.assert(@sizeOf(AppendPositionHeader) == 24);
    std.debug.assert(@sizeOf(CommitPositionHeader) == 24);
    std.debug.assert(@sizeOf(RequestVoteHeader) == 40);
    std.debug.assert(@sizeOf(VoteHeader) == 40);
}
```

These assertions fire at compile-time if:
- Zig adds unexpected padding (e.g., due to a Zig version change)
- You accidentally modify a field and break alignment
- The struct drifts from the protocol spec

## Exercise

**Implement comptime size assertions for the cluster protocol.**

Open `src/cluster/protocol.zig` and add a `comptime` block that verifies:
1. `AppendRequestHeader` is exactly 32 bytes
2. `VoteHeader` is exactly 40 bytes
3. `NewLeadershipTermHeader` is exactly 40 bytes

You can copy the pattern from above; just add the `std.debug.assert` lines for each struct in a block at the end of the file.

**Acceptance criteria:**
- All three assertions pass at compile-time (no errors)
- `zig build` completes without errors
- You can explain why `AppendRequestHeader` must be 32 bytes (three 64-bit fields + one explicit 32-bit padding)

## Check Your Work

```bash
cd /Users/azusachino/Projects/project-github/harus-aeron-zig
zig build
```

If the build succeeds, the assertions passed.

## Key Takeaways

1. **Raft coordination is message-driven**: every state change (election, replication, commit) is signaled by a fixed-size binary message.
2. **extern struct + explicit _padding**: we use C ABI layout and make padding explicit, so multiplatform shared memory is safe and predictable.
3. **Three message families**: Client (201–204) for application ingress, Consensus (211–216) for cluster coordination, Service (221–230) for delivery to the service layer.
4. **Correlation IDs**: every client request gets an opaque ID that the server echoes back, enabling async multiplexing without a shared request queue.
5. **Variable-length fields**: like archive protocol, cluster messages use a length-prefixed pattern (channel string, log entries) to stay wire-compatible across languages.

Next, we'll see how these messages drive the Raft election state machine.
