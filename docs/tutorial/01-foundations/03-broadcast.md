# 1.3 Broadcast Buffer

The ring buffer in chapter 1.2 solves the client-to-driver direction: many writers, one reader. The reverse — driver to clients — needs the opposite: one writer, many readers. Each client must receive every notification independently. A conventional ring buffer cannot do this; advancing the head for one reader would consume the record for all others.

Aeron solves this with a broadcast buffer: `src/ipc/broadcast.zig`.

## One Writer, Many Independent Readers

In the broadcast design, the transmitter (driver) writes into a single shared buffer and advances a tail cursor. Each receiver maintains its own head cursor. Readers do not coordinate with each other and do not modify shared state during a read. The only shared mutable value is the transmitter's tail, which is read-only from the receiver's perspective.

```
Transmitter
  tail ──────────────────────────────────────────────────────────►
                                                             ▲
  buffer:  [ record ][ record ][ record ][ record ][ ... ]
                                  ▲              ▲
  Receiver A head ────────────────┘              │
  Receiver B head ───────────────────────────────┘
```

Because receivers only advance their own local head, adding a new subscriber has zero cost to the transmitter or to other subscribers.

## Record Layout

`RecordDescriptor.HEADER_LENGTH = 12`: type (4 bytes), length (4 bytes), reserved (4 bytes).

```
+--- 4 bytes ---+--- 4 bytes ---+--- 4 bytes ---+--- data bytes ---+--- pad ---+
|  msg_type_id  |    length     |   reserved    |     payload      | alignment |
+---------------+---------------+---------------+------------------+-----------+
```

Records are aligned to `RecordDescriptor.ALIGNMENT = 8` bytes. The `aligned` helper accounts for the header:

```zig
pub fn aligned(length: usize) usize {
    return std.mem.alignForward(usize, length + HEADER_LENGTH, ALIGNMENT);
}
```

## Write Side: BroadcastTransmitter

`BroadcastTransmitter` owns the buffer and the tail cursor. The `transmit` method:

1. Loads the current tail.
2. Computes the next tail after aligning the record.
3. Writes the record header (type, length, reserved) at the current tail offset.
4. Copies the payload bytes.
5. Advances the tail atomically with `.seq_cst` ordering.

The tail is a `*std.atomic.Value(usize)`, allocated just past the end of the data buffer so it shares the same allocation:

```zig
pub const BroadcastTransmitter = struct {
    buffer: []u8,
    capacity: usize,
    tail: *std.atomic.Value(usize),
    ...
};
```

`seq_cst` (sequentially consistent) ordering is used here because broadcast correctness depends on all readers seeing writes in the same order as the transmitter produced them. This is stronger than required for a single-writer scenario but matches the Java reference implementation's `volatile` semantics.

## Read Side: BroadcastReceiver

`BroadcastReceiver` holds a reference to the shared buffer and the transmitter's tail, plus its own private state:

```zig
pub const BroadcastReceiver = struct {
    shared_buffer: []u8,
    capacity: usize,
    transmitter_tail: *std.atomic.Value(usize), // read-only from receiver
    head: usize,          // receiver's own cursor — not shared
    record_offset: i32,
    record_length: i32,
    record_type_id: i32,
};
```

`receiveNext` advances through the buffer one record at a time:

1. Load transmitter tail with `.seq_cst`.
2. If `head >= tail`: nothing new, return false.
3. Read the 12-byte record header at `head`.
4. Decode `msg_type_id` and `record_length`.
5. Store `record_offset` pointing to the payload start.
6. Advance `head` by `aligned(record_length)` modulo capacity.
7. Return true.

The caller then calls `typeId()`, `buffer()`, and `length()` to access the record. These are pure accessors with no shared state.

## The Latch: Detecting Torn Reads

A fast-running transmitter can lap a slow receiver — writing new records over old ones the receiver has not yet read. This is called being "lapped." The receiver detects it with the `lapped` method, which compares the transmitter's tail to the receiver's head. In the full Aeron implementation, a version counter (written before and after each record) lets the receiver detect a torn read mid-access: if the version after reading differs from the version before, the record was overwritten during the read and must be discarded and retried.

The latch sequence on the write side looks like:

```
version++  (odd = write in progress)
write header + payload
version++  (even = write complete)
```

The read side:
```
v1 = load version
read record
v2 = load version
if v1 != v2 or v1 is odd → torn read, retry
```

This is not a lock — no thread ever waits. A receiver that is repeatedly lapped simply re-syncs its head to the transmitter's current tail and continues, at the cost of missing intervening records.

## Callbacks in Zig: `*const fn` and `*anyopaque`

The term reader pattern used downstream passes a fragment handler as a function pointer plus a context pointer:

```zig
pub const MessageHandler = *const fn (msg_type_id: i32, data: []const u8, ctx: *anyopaque) void;
```

`*const fn(...)` is a typed function pointer — no vtable, no allocation. `*anyopaque` carries caller state without generics, keeping the interface simple. The caller casts:

```zig
handler(type_id, record_data, @ptrCast(&my_state));
// inside handler:
const s: *MyState = @ptrCast(@alignCast(ctx));
```

`@alignCast` inserts a runtime assertion (in debug builds) that the pointer is correctly aligned for `MyState`.

## Key File

`src/ipc/broadcast.zig` — `BroadcastTransmitter`, `BroadcastReceiver`, `RecordDescriptor`, and the `lapped` detection logic.
