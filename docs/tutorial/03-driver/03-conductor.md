# 3.3 The Conductor

The Conductor is the command/control centre of the media driver. It does not touch UDP sockets. Instead it reads client commands from a ring buffer, allocates or releases driver resources, and posts responses to a broadcast channel that all connected clients can read.

## Role and Responsibilities

- Drain client commands from `ManyToOneRingBuffer`.
- For `ADD_PUBLICATION`: allocate a log buffer, assign a session ID, record a `PublicationEntry`, respond with `ON_PUBLICATION_READY`.
- For `ADD_SUBSCRIPTION`: record a `SubscriptionEntry`, respond with `ON_SUBSCRIPTION_READY`.
- For `REMOVE_*`: release the entry and free heap allocations.
- For `CLIENT_KEEPALIVE`: reset the liveness timer for that client.
- For `ADD_COUNTER` / `REMOVE_COUNTER`: manage the shared counters slab.
- Detect client liveness timeouts and disconnect idle clients.

## Command Lifecycle: ADD_PUBLICATION

```
Client                     Ring Buffer            Conductor
  │                             │                     │
  │── write ADD_PUBLICATION ──>│                     │
  │   [correlation_id: i64,    │                     │
  │    stream_id: i32,         │                     │
  │    channel_len: i32,       │                     │
  │    channel: []u8]          │                     │
  │                             │── read message ───>│
  │                             │                    │── allocate PublicationEntry
  │                             │                    │── assign next_session_id
  │                             │                    │── store channel copy
  │                             │                    │
  │<──────── Broadcast ON_PUBLICATION_READY ─────────│
  │          [correlation_id, session_id, stream_id]  │
```

The conductor increments `next_session_id` for each new publication. The client matches the response to its request via `correlation_id`.

### handleAddPublication

```zig
fn handleAddPublication(self: *DriverConductor, data: []const u8) void {
    const correlation_id = std.mem.readInt(i64, data[0..8], .little);
    const stream_id      = std.mem.readInt(i32, data[8..12], .little);
    const channel_len    = std.mem.readInt(i32, data[12..16], .little);
    const channel_data   = data[16..16 + @as(usize, @intCast(channel_len))];

    const channel_copy = self.allocator.dupe(u8, channel_data) catch return;
    const session_id   = self.next_session_id;
    self.next_session_id += 1;

    self.publications.append(self.allocator, .{
        .registration_id = correlation_id,
        .session_id      = session_id,
        .stream_id       = stream_id,
        .channel         = channel_copy,
        .ref_count       = 1,
    }) catch { self.allocator.free(channel_copy); return; };

    self.sendPublicationReady(correlation_id, session_id, stream_id);
}
```

Key points: every allocation has an error path. The channel string is heap-owned and freed in `deinit` or `handleRemovePublication`. The response is written to the broadcast buffer synchronously before `doWork` returns.

## The Publication and Subscription Maps

Publications and subscriptions are stored as `std.ArrayList` of entry structs:

```zig
pub const PublicationEntry = struct {
    registration_id: i64,
    session_id:      i32,
    stream_id:       i32,
    channel:         []u8,   // heap-owned
    ref_count:       i32,
};

pub const SubscriptionEntry = struct {
    registration_id: i64,
    stream_id:       i32,
    channel:         []u8,   // heap-owned
};
```

Removal scans the list linearly and uses `swapRemove` for O(1) deletion. The conductor holds exclusive access to these lists — only one conductor thread runs, so no synchronisation is needed.

## Tagged Unions and Exhaustive Switch

The command dispatch function is `handleMessage`, which the ring buffer calls for each message:

```zig
fn handleMessage(msg_type_id: i32, data: []const u8, ctx: *anyopaque) void {
    const self: *DriverConductor = @ptrCast(@alignCast(ctx));
    switch (msg_type_id) {
        CMD_ADD_PUBLICATION    => self.handleAddPublication(data),
        CMD_REMOVE_PUBLICATION => self.handleRemovePublication(data),
        CMD_ADD_SUBSCRIPTION   => self.handleAddSubscription(data),
        CMD_REMOVE_SUBSCRIPTION => self.handleRemoveSubscription(data),
        CMD_CLIENT_KEEPALIVE   => self.handleClientKeepalive(data),
        CMD_ADD_COUNTER        => self.handleAddCounter(data),
        CMD_REMOVE_COUNTER     => self.handleRemoveCounter(data),
        else => {},
    }
}
```

Because `msg_type_id` is a raw `i32` from IPC, the `else` branch is required for unknown commands. If the commands were encoded as a Zig `enum`, you could use a **tagged union** instead:

```zig
const Command = union(enum) {
    add_publication:    AddPublicationCmd,
    remove_publication: RemovePublicationCmd,
    add_subscription:   AddSubscriptionCmd,
    // ...
};

switch (cmd) {
    .add_publication    => |c| self.handleAddPublication(c),
    .remove_publication => |c| self.handleRemovePublication(c),
    // compiler error if any variant is missing and no else branch
}
```

Exhaustive switch means the compiler refuses to compile if a new command variant is added without a handler. This is a strong invariant for command dispatch — no runtime default, no silent drop.

## Response Functions

Each response is serialised into a small stack buffer and written to the broadcast transmitter:

```zig
fn sendPublicationReady(self: *DriverConductor, correlation_id: i64,
                        session_id: i32, stream_id: i32) void {
    var buf: [16]u8 = undefined;
    std.mem.writeInt(i64, buf[0..8],  correlation_id, .little);
    std.mem.writeInt(i32, buf[8..12], session_id,     .little);
    std.mem.writeInt(i32, buf[12..16], stream_id,     .little);
    self.broadcaster.transmit(RESPONSE_ON_PUBLICATION_READY, &buf);
}
```

Broadcast transmit is a lock-free append to a circular buffer. Clients poll that buffer independently.

## Client Liveness

`handleClientKeepalive` resets a per-client timestamp. A background scan in `doWork` would evict any client whose last keepalive is older than `client_liveness_timeout_ns` (default 5 seconds). The current implementation records the intent in `handleClientKeepalive`; production would close all publications and subscriptions owned by the dead client.

## Function Reference

| Function | Purpose |
|---|---|
| `init` | Initialise publication and subscription lists |
| `deinit` | Free all heap-owned channel strings and lists |
| `doWork` | Read up to 10 commands from the ring buffer |
| `handleMessage` | Dispatch by command type ID (ring buffer callback) |
| `handleAddPublication` | Allocate entry, assign session ID, send ready |
| `handleRemovePublication` | Find and remove entry, free channel string |
| `handleAddSubscription` | Allocate entry, send ready |
| `handleRemoveSubscription` | Find and remove entry, free channel string |
| `handleClientKeepalive` | Reset liveness timestamp for client |
| `handleAddCounter` | Allocate a slot in the counters map |
| `handleRemoveCounter` | Free a counter slot |
| `sendPublicationReady` | Broadcast ON_PUBLICATION_READY |
| `sendSubscriptionReady` | Broadcast ON_SUBSCRIPTION_READY |
| `sendError` | Broadcast ON_ERROR with code and message |
| `sendCounterReady` | Broadcast ON_COUNTER_READY |
