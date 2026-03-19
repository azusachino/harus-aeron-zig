# 1.2 Ring Buffer

The client and the media driver live in separate processes. To issue a command — add a publication, remove a subscription — the client writes a message into a shared-memory ring buffer. The driver polls it. There is no syscall in the write path, no mutex, and no kernel involvement until the operating system schedules the driver thread.

The implementation is `ManyToOneRingBuffer` in `src/ipc/ring_buffer.zig`, modeled on Agrona's Java implementation.

## Buffer Layout

The ring buffer is a flat byte slice. The last 128 bytes are reserved metadata; everything before that is the data region whose byte capacity is called `capacity`.

```
+------- capacity bytes ---------+--- 128 bytes metadata ---+
|  record  | record  |  pad  |...|  tail | head_cache | head | corr | ...  |
+----------+---------+-------+---+--------------------------+
```

Metadata offsets (from `capacity`):

| Constant | Offset | Purpose |
|---|---|---|
| `TAIL_POSITION_OFFSET` | 0 | Writer cursor (absolute, monotonically increasing) |
| `HEAD_CACHE_POSITION_OFFSET` | 8 | Cached copy of head, read by writers |
| `HEAD_POSITION_OFFSET` | 16 | Reader cursor (absolute) |
| `CORRELATION_COUNTER_OFFSET` | 24 | Monotonic counter for correlation IDs |

Both tail and head are `i64` and are never wrapped — they grow without bound. The actual buffer index is `position % capacity`. This avoids the ambiguity between "empty" and "full" that trips up many ring buffer implementations.

## Record Layout

Each written message becomes a record in the data region:

```
+--- 4 bytes ---+--- 4 bytes ---+--- data_len bytes ---+--- padding ---+
|  msg_type_id  |    length     |        payload        |   alignment   |
+---------------+---------------+----------------------+---------------+
```

`RecordDescriptor.HEADER_LENGTH = 8`. `length` stores `HEADER_LENGTH + data.len` — the total occupied bytes including the header. Records are padded to `ALIGNMENT = 8` bytes so the next record always starts aligned.

The `aligned` helper:

```zig
pub fn aligned(length: usize) usize {
    return std.mem.alignForward(usize, length + HEADER_LENGTH, ALIGNMENT);
}
```

For a 5-byte payload: `alignForward(13, 8) = 16`. The record occupies 16 bytes in the buffer.

## Write Protocol

```
1. Load tail (atomic acquire)
2. Check if (tail % capacity) + aligned_length > capacity
   → if yes: insert padding record at end, wrap tail to 0
3. CAS tail from old value to old + aligned_length
   → if CAS fails: reload tail, retry from step 2
4. Write msg_type_id to record header
5. Copy payload bytes
6. Store length with ordered write (commits the record)
```

The CAS loop handles multiple concurrent writers. Only one writer wins the tail range; others retry. The length field is written last and acts as a publication flag: a reader that sees `length == 0` knows the slot is not yet committed.

In Zig, the CAS is:

```zig
const result = @cmpxchgStrong(i64, ptr, expected, new, .acq_rel, .acquire);
return result == null; // null means the swap succeeded
```

`.acq_rel` on success provides a full barrier: prior writes visible to any thread that subsequently acquires. `.acquire` on failure re-reads the current value with acquire semantics so the retry sees up-to-date state.

## Read Protocol

The reader is single-threaded by design (One in ManyToOne). Reading is straightforward:

```
1. Load head (atomic acquire)
2. Read msg_type_id at (head % capacity)
   → 0: no record committed yet — stop
   → PADDING_MSG_TYPE_ID (-1): skip, advance head by padding length
   → anything else: dispatch to handler, advance head by aligned length
3. Store head (atomic release) after processing up to `limit` records
```

The `read` function accepts a `MessageHandler` and a `*anyopaque` context pointer:

```zig
pub const MessageHandler = *const fn (msg_type_id: i32, data: []const u8, ctx: *anyopaque) void;

pub fn read(self: *ManyToOneRingBuffer, handler: MessageHandler, ctx: *anyopaque, limit: i32) i32
```

The `*anyopaque` pattern is Zig's equivalent of `void *` — the caller casts their own state to `*anyopaque` when calling `read`, and casts back inside the handler. It avoids allocating a closure.

## Why No Mutex

A mutex would serialize all writers, adding kernel overhead and priority inversion risk. The CAS loop is cheaper for low-contention cases (the common case: one client, one driver). Under high contention the CAS retries, but the critical section — claim a tail range — is a single atomic word operation. The actual data copy happens outside the CAS, so writers do not block each other during the slow memcpy.

Head is only written by the single reader, so storing it needs no CAS — a plain atomic store with `.release` ordering suffices.

## Padding Records

When a record would straddle the end of the buffer, a padding record (`PADDING_MSG_TYPE_ID = -1`) is inserted to fill the remaining space, and the tail wraps to zero. The reader recognizes this sentinel and skips the padding without dispatching it to the handler.

## Correlation IDs

`nextCorrelationId` uses an atomic fetch-and-add on the metadata region:

```zig
const current = @atomicRmw(i64, ptr, .Add, 1, .acq_rel);
return current + 1;
```

Each command written to the ring buffer carries a correlation ID. When the driver broadcasts its response, it echoes the same ID, allowing the client to match responses to requests without any shared state.

## Key File

`src/ipc/ring_buffer.zig` — `ManyToOneRingBuffer`, `RecordDescriptor`, `MessageHandler`, metadata offset constants, and unit tests covering alignment, wrap-around, and correlation ID monotonicity.
