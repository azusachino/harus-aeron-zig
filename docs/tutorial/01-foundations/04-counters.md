# 1.4 Counters

Aeron's flow control does not use a traditional credit-based windowing protocol at the application layer. Instead, publisher and subscriber positions are maintained as shared-memory counters that both the driver and client can read without crossing a syscall boundary. The driver sets a publisher limit; the publisher reads it before writing to the log buffer; the subscriber advances its position counter as it consumes frames.

Everything lives in `src/ipc/counters.zig`.

## Why Shared-Memory Counters

A position counter is an `i64` that one thread writes and many threads read. If this were a socket message or a system call, each read would cost hundreds of nanoseconds. With shared memory, a read is a cache-line load — roughly 5 ns when the value is in L3 cache, and under 1 ns when it is in L1.

The challenge is keeping reads and writes coherent across CPU cores. The answer is a combination of volatile-equivalent atomic loads/stores and careful cache-line layout.

## Counter Types

Five pre-defined counter type IDs are declared in `src/ipc/counters.zig`:

| Constant | ID | Used For |
|---|---|---|
| `PUBLISHER_LIMIT` | 0 | Max position the publisher may write to |
| `SENDER_POSITION` | 1 | How far the sender has transmitted |
| `RECEIVER_HWM` | 2 | Highest watermark seen by the receiver |
| `SUBSCRIBER_POSITION` | 3 | How far a subscriber has consumed |
| `CHANNEL_STATUS` | 4 | Active/inactive/errored channel state |

## Cache-Line Alignment

Modern CPUs transfer memory in 64-byte cache lines. If two counters share a cache line, a write to one invalidates the other on every other core — even if they are logically independent. This is false sharing. Aeron eliminates it by giving each counter its own 64-byte slot:

```zig
pub const COUNTER_LENGTH: usize = 64; // Cache line size
```

Every counter occupies exactly one cache line in the values buffer. The values buffer is laid out as a flat array of 64-byte slots, indexed by `counter_id`:

```
values_buffer:
  [  slot 0 (64 bytes) ][  slot 1 (64 bytes) ][  slot 2 (64 bytes) ]...
      publisher_limit       sender_position        receiver_hwm
```

Byte offset for `counter_id`:

```zig
const offset = @as(usize, @intCast(counter_id)) * COUNTER_LENGTH;
```

The first 8 bytes of each slot hold the `i64` counter value. The remaining 56 bytes are padding — never accessed, but essential to prevent any other data from sharing the cache line.

In test code, buffers are declared with explicit alignment:

```zig
var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
```

`align(64)` ensures the first slot begins on a 64-byte boundary. Without it, a slot might straddle two cache lines and defeat the purpose.

## Metadata Layout

Each counter also has a 1024-byte metadata entry in a separate metadata buffer. The metadata holds the counter's state, type ID, key bytes, and a human-readable label:

| Constant | Offset | Type | Purpose |
|---|---|---|---|
| `RECORD_STATE_OFFSET` | 0 | i32 | `UNUSED=0`, `ALLOCATED=1`, `RECLAIMED=-1` |
| `TYPE_ID_OFFSET` | 4 | i32 | Counter type (e.g. `PUBLISHER_LIMIT`) |
| `FREE_TO_REUSE_DEADLINE_OFFSET` | 8 | i64 | Epoch time after which slot is reusable |
| `KEY_LENGTH_OFFSET` | 16 | i32 | Length of key bytes |
| `KEY_DATA_OFFSET` | 20 | bytes | Opaque key blob |
| `LABEL_OFFSET` | 512 | i32 + string | Label length + UTF-8 text |

`METADATA_LENGTH = 1024` per counter. The metadata and values buffers are sized independently:

```zig
pub const CountersMap = struct {
    meta_buffer: []u8,
    values_buffer: []u8,
    max_counters: usize,

    pub fn init(meta: []u8, values: []u8) CountersMap {
        const max_counters = @min(meta.len / METADATA_LENGTH, values.len / COUNTER_LENGTH);
        ...
    }
};
```

## Atomic Reads and Writes

Counter values are read and written with acquire/release ordering:

```zig
pub fn get(self: *const CountersMap, counter_id: i32) i64 {
    const offset = @as(usize, @intCast(counter_id)) * COUNTER_LENGTH;
    const ptr: *i64 = @ptrCast(@alignCast(&self.values_buffer[offset]));
    return @atomicLoad(i64, ptr, .acquire);
}

pub fn set(self: *CountersMap, counter_id: i32, value: i64) void {
    const offset = @as(usize, @intCast(counter_id)) * COUNTER_LENGTH;
    const ptr: *i64 = @ptrCast(@alignCast(&self.values_buffer[offset]));
    @atomicStore(i64, ptr, value, .release);
}
```

`.release` on a store ensures all prior writes are visible to any thread that subsequently does an `.acquire` load on the same address. This is the minimum ordering needed to safely communicate a position between a writer and a reader on different cores — no full barrier required.

For increment operations (e.g., advancing `SENDER_POSITION`), `addOrdered` uses a fetch-and-add:

```zig
_ = @atomicRmw(i64, ptr, .Add, delta, .release);
```

For flow-control decisions that need a conditional update (e.g., the driver setting `PUBLISHER_LIMIT`), `compareAndSet` wraps `@cmpxchgStrong`:

```zig
return @cmpxchgStrong(i64, ptr, expected, update, .acq_rel, .acquire) == null;
```

## Allocation and Reclaim

`CountersMap.allocate` scans the metadata buffer for a slot in state `UNUSED` or `RECLAIMED`, initializes its metadata, then atomically sets state to `ALLOCATED`. The state transition uses an atomic store so readers see a consistent snapshot. `free` sets state to `RECLAIMED` and zeros the value, making the slot eligible for reuse after the deadline passes.

## Key File

`src/ipc/counters.zig` — `CountersMap`, `CounterHandle`, counter type constants, metadata offset constants, and tests for allocate/free/get/set/compareAndSet.
