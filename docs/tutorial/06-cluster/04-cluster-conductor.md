# 6.4 Cluster Conductor

The **conductor** is the central dispatcher of a cluster node. It manages three concerns:

1. **Client session lifecycle**: accept connections, route messages, handle disconnections
2. **Replication supervision**: monitor follower ACKs and trigger commit advances
3. **Service delivery**: hand committed entries to the application layer

Think of it as a switchboard that routes inbound messages (from clients, from other nodes) through the consensus log and out to the service.

## What You'll Build

By the end of this chapter, you'll understand:
- Client session lifecycle: connect → SessionConnectRequest → SessionEvent(ok) → messages → disconnect
- How cluster session messages wrap application messages (SessionMessageHeader)
- The redirect flow (when client connects to a follower, gets redirected to leader)
- How the service interface is invoked (function pointer callbacks)
- The difference between leader and follower conductors

## Why It Works This Way (Aeron Concept)

In a cluster, **there is one leader and many followers**. The conductor handles this asymmetry:

**On the Leader**:
- Accepts `SessionConnectRequest` from clients on the ingress channel
- Creates a session and assigns it a `cluster_session_id`
- When the client sends `SessionMessage`, the leader appends it to the cluster log
- Once a quorum ACKs and the entry is committed, the leader passes it to the service layer
- Service processes the message and generates a response
- Response is published back to the client on the client's response channel

**On a Follower**:
- Accepts `SessionConnectRequest` but sends `SessionEvent(redirect)` with the current leader's ID
- Client reconnects to the leader
- Follower silently receives replicated log entries from the leader via `AppendRequest`
- Once entries are committed, follower passes them to the service layer
- Service processes the message **identically** to how the leader did
- This is deterministic state machine replication (DSMR): all replicas do the same computation

### Session Lifecycle

```mermaid
sequenceDiagram
    participant Client
    participant Leader
    participant Service

    Client->>Leader: SessionConnectRequest(correlation_id=42, response_channel="...")
    Note over Leader: Create session, assign cluster_session_id=10

    Leader->>Client: SessionEvent(session_id=10, correlation_id=42, event_code=OK)

    Client->>Leader: SessionMessage(session_id=10, data="hello")
    Note over Leader: Append to log

    Leader->>Follower: AppendRequest(data="hello")
    Follower->>Leader: AppendPosition(pos=100)

    Note over Leader: Quorum reached; advance commit_position

    Leader->>Service: Deliver committed entry (session_id=10, data="hello")
    Service->>Service: Process message
    Service->>Leader: Return response

    Leader->>Client: Response on response channel
```

Notice:
- Client's `correlation_id` is echoed in `SessionEvent` to pair request and response
- Client's `response_channel` is remembered so the leader knows where to send replies
- Service is invoked only after commit (safe for crash recovery)

### Role-Based Behavior

```zig
pub const ClusterConductor = struct {
    role: ClusterRole,  // leader, follower, or candidate
    sessions: std.StringHashMap(SessionState),
    next_session_id: i64 = 1,
    // ...

    pub fn onSessionConnect(self: *ClusterConductor, req: SessionConnectRequest) !void {
        if (self.role == .leader) {
            // Create session and send OK
            const session_id = self.next_session_id;
            self.next_session_id += 1;
            try self.sessions.put(session_id, SessionState{
                .cluster_session_id = session_id,
                .response_stream_id = req.response_stream_id,
                // ... decode response_channel from buffer
            });
            // Publish SessionEvent(ok) back to client
        } else {
            // I'm a follower; redirect to leader
            // Publish SessionEvent(redirect, leader_member_id=...)
        }
    }

    pub fn onSessionMessage(self: *ClusterConductor, msg: SessionMessage) !void {
        if (self.role != .leader) {
            // Followers don't accept client messages; client should reconnect to leader
            return;
        }
        // Append to cluster log (replication happens automatically)
        try self.log.append(msg.data, msg.timestamp);
    }

    pub fn deliverCommittedEntries(self: *ClusterConductor) !void {
        // Service reads committed entries and processes them
        const committed = self.log.committedEntries();
        for (committed) |entry| {
            if (entry.position > self.last_delivered_position) {
                try self.service.onMessage(entry.data);
                self.last_delivered_position = entry.position;
            }
        }
    }
};
```

## Zig Concept: `comptime` Function Pointer for Service Callbacks

How do we invoke the service without tight coupling? We use **function pointers**.

### Standalone Example

```zig
const std = @import("std");

// Service callback signature
pub const ServiceFn = *const fn (context: *anyopaque, data: []const u8) void;

// Service interface
pub const Service = struct {
    on_message: ServiceFn,
    context: *anyopaque,

    pub fn deliverMessage(self: *Service, data: []const u8) void {
        self.on_message(self.context, data);
    }
};

// Application service implementation
pub const MyService = struct {
    state: i32 = 0,

    pub fn onMessage(ctx: *anyopaque, data: []const u8) void {
        const self = @as(*MyService, @ptrCast(@alignCast(ctx)));
        self.state += 1;
    }
};

pub fn main() void {
    var my_service = MyService{};
    const service = Service{
        .on_message = MyService.onMessage,
        .context = @ptrCast(&my_service),
    };

    service.deliverMessage("hello");
    // my_service.state is now 1
}
```

The key is `*anyopaque`: an opaque pointer. We cast it back to the actual type in the callback. This allows:
- **Loose coupling**: conductor doesn't know the concrete service type
- **Zero runtime overhead**: no vtables, no heap allocation (the callback is statically known)
- **Compile-time verification**: Zig checks that the function pointer signature matches

In real Aeron, the conductor calls a `ClusteredService` interface:
```zig
pub const ClusteredService = struct {
    on_session_open: ServiceFn,
    on_session_message: ServiceFn,
    on_session_close: ServiceFn,
    context: *anyopaque,
};
```

## The Code

Open `src/cluster/conductor.zig`:

```zig
pub const ClusterRole = enum {
    leader,
    follower,
    candidate,
};

pub const SessionState = struct {
    cluster_session_id: i64,
    response_stream_id: i32,
    response_channel: []u8,
    is_open: bool = true,
};

pub const SessionConnectCmd = struct {
    correlation_id: i64,
    cluster_session_id: i64,
    response_stream_id: i32,
    response_channel: []const u8,
};

pub const SessionMessageCmd = struct {
    cluster_session_id: i64,
    timestamp: i64,
    data: []const u8,
};

pub const Command = union(enum) {
    session_connect: SessionConnectCmd,
    session_close: SessionCloseCmd,
    session_message: SessionMessageCmd,
    append_position: AppendPositionCmd,
    commit_position: CommitPositionCmd,
};

pub const ClusterConductor = struct {
    allocator: std.mem.Allocator,
    role: ClusterRole = .follower,
    member_id: i32,
    leader_member_id: i32 = -1,
    leader_ship_term_id: i64 = 0,

    // Session management
    sessions: std.AutoHashMap(i64, SessionState),
    next_session_id: i64 = 1,

    // Log state
    log: log_mod.ClusterLog,

    pub fn init(allocator: std.mem.Allocator, member_id: i32) ClusterConductor {
        return .{
            .allocator = allocator,
            .member_id = member_id,
            .sessions = std.AutoHashMap(i64, SessionState).init(allocator),
            .log = log_mod.ClusterLog.init(allocator),
        };
    }

    pub fn deinit(self: *ClusterConductor) void {
        // Clean up sessions
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.response_channel);
        }
        self.sessions.deinit();
        self.log.deinit();
    }

    /// Handle a client connection request.
    pub fn onSessionConnect(
        self: *ClusterConductor,
        correlation_id: i64,
        response_stream_id: i32,
        response_channel: []const u8,
    ) !void {
        if (self.role != .leader) {
            // Send redirect to client
            // (In a real implementation, publish SessionEvent(redirect, leader_member_id))
            return;
        }

        // Create new session
        const session_id = self.next_session_id;
        self.next_session_id += 1;

        const owned_channel = try self.allocator.dupe(u8, response_channel);
        try self.sessions.put(session_id, SessionState{
            .cluster_session_id = session_id,
            .response_stream_id = response_stream_id,
            .response_channel = owned_channel,
            .is_open = true,
        });

        // Publish SessionEvent(ok) back to client
        // (In a real implementation, this would be published on the response channel)
    }

    /// Handle a session message from a client.
    pub fn onSessionMessage(
        self: *ClusterConductor,
        session_id: i64,
        timestamp: i64,
        data: []const u8,
    ) !void {
        if (self.role != .leader) {
            // Followers don't accept client messages
            return;
        }

        // Check session exists
        if (!self.sessions.contains(session_id)) {
            // Send error to client
            return;
        }

        // Append to cluster log
        _ = try self.log.append(data, timestamp);
    }

    /// Deliver all committed entries to the service.
    pub fn deliverCommittedEntries(self: *ClusterConductor) !void {
        const committed = self.log.committedEntries();
        for (committed) |entry| {
            // Pass to service layer
            // service.on_session_message(service.context, entry.data);
        }
    }

    /// Handle commit position update from replication.
    pub fn onCommitPosition(self: *ClusterConductor, position: i64) void {
        self.log.canCommit(position);
    }

    /// Handle follower ACK for replication.
    pub fn onAppendPosition(
        self: *ClusterConductor,
        follower_member_id: i32,
        position: i64,
    ) void {
        if (self.role == .leader) {
            // Track this follower's progress
            // leader_log.onAppendPosition(follower_member_id, position);
        }
    }
};
```

Notice:
- `role` determines behavior: leader accepts connections, followers redirect
- `sessions` map tracks open client sessions
- `log` is the shared replication log
- `onSessionConnect` creates a session and remembers the response channel
- `onSessionMessage` appends to the log
- `deliverCommittedEntries` passes committed entries to the service

## Exercise

**Implement `onSessionConnect`: validate request, create session, send SessionEvent(ok).**

Open `tutorial/cluster/conductor.zig` and implement:

```zig
/// Handle a client connection request.
/// If leader: create session and send SessionEvent(ok).
/// If follower: send SessionEvent(redirect).
pub fn onSessionConnect(
    self: *ClusterConductor,
    correlation_id: i64,
    response_stream_id: i32,
    response_channel: []const u8,
) !void {
    // TODO: implement
    @panic("TODO: onSessionConnect");
}
```

**Acceptance criteria:**
1. If `role == .follower`, return early (don't process)
2. If `role == .leader`:
   - Allocate a new `cluster_session_id` (increment `next_session_id`)
   - Create a `SessionState` with the response channel
   - Store in `sessions` map
3. Write a test: create a leader conductor, connect a session, verify the session exists

Compare against `src/cluster/conductor.zig`.

## Check Your Work

```bash
cd /Users/azusachino/Projects/project-github/harus-aeron-zig
make test-unit
```

Look for tests named `test_conductor_*` or `test_session_*`.

## Key Takeaways

1. **Conductor is the switchboard**: routes client ingress, monitors replication, delivers to service.
2. **Leaders and followers differ**: only leaders accept client connections; followers redirect.
3. **Sessions are stateful**: each client gets a unique `cluster_session_id` and a response channel.
4. **Service callbacks use function pointers**: no tight coupling, no overhead.
5. **Committed entries are safe to process**: if a service crashes and restarts, it replays from the committed log, recovering its state deterministically.

Next, we'll see how all these pieces fit together in the ConsensusModule.
