# 1.5 Log Buffer

The log buffer is where messages actually live. A publisher does not send directly to the network; it writes frames into a log buffer term. The sender reads from there. A subscriber's image also points to a log buffer; the receiver writes incoming frames into it and the subscriber polls it. The log buffer is the central data structure of the Aeron data path.

The implementation is `src/logbuffer/log_buffer.zig` with metadata in `src/logbuffer/metadata.zig`.

## The Three-Term Ring

A log buffer contains three term buffers — not one. Terms rotate: at any moment one term is active (being written), one is dirty (recently filled, being drained by the sender), and one is clean (zeroed, ready to become the next active term).

```
  terms[0]          terms[1]          terms[2]
+------------+    +------------+    +------------+
|   active   |    |   dirty    |    |   clean    |
|  (writing) |    | (draining) |    |   (ready)  |
+------------+    +------------+    +------------+
         active_term_count % 3 == 0 → terms[0] is active
```

When a publisher fills the active term, it increments `active_term_count`. The new active index is `active_term_count % PARTITION_COUNT`. The old active term becomes dirty; the previous dirty term (now fully sent) becomes clean. This rotation happens without any reallocation — the same three buffers cycle indefinitely.

`PARTITION_COUNT = 3` is a protocol constant, not a configuration value. It must be 3.

## Term Size

Each term is a fixed-size contiguous byte buffer. The size must be a power of two, between `TERM_MIN_LENGTH = 64 * 1024` and `TERM_MAX_LENGTH = 1 * 1024 * 1024 * 1024`. The default in production Aeron is 16 MB.

Power-of-two sizes allow the term index to be computed from an absolute position with a bitmask instead of a division:

```
term_offset = absolute_position & (term_length - 1)
term_index  = (absolute_position >> log2(term_length)) % PARTITION_COUNT
```

This is why term appenders can compute positions with bitwise arithmetic only — no modulo on a variable divisor.

## Metadata Section

Every log buffer has a 4096-byte metadata section (`LOG_META_DATA_LENGTH`) that records state shared between the publisher, driver, and subscribers:

| Constant | Offset | Type | Purpose |
|---|---|---|---|
| `TERM_TAIL_COUNTERS_OFFSET` | 0 | i64[3] | Raw tail for each partition (term_id in high 32 bits, offset in low 32) |
| `LOG_ACTIVE_TERM_COUNT_OFFSET` | 24 | i32 | Monotonically increasing rotation counter |

The tail counters are packed `i64` values: the upper 32 bits hold the `term_id` and the lower 32 bits hold the byte offset within the term. This packing lets the term appender CAS both fields atomically in a single 64-bit operation.

`LogBufferMetadata` in `metadata.zig` wraps the raw byte slice and provides typed accessors:

```zig
pub fn activeTermCount(self: *const LogBufferMetadata) i32 {
    const ptr: *i32 = @ptrCast(@alignCast(&self.buffer[LOG_ACTIVE_TERM_COUNT_OFFSET]));
    return @atomicLoad(i32, ptr, .acquire);
}

pub fn setActiveTermCount(self: *LogBufferMetadata, val: i32) void {
    const ptr: *i32 = @ptrCast(@alignCast(&self.buffer[LOG_ACTIVE_TERM_COUNT_OFFSET]));
    @atomicStore(i32, ptr, val, .release);
}
```

## LogBuffer Struct

`LogBuffer` in `log_buffer.zig` holds the three term slices and the metadata raw bytes:

```zig
pub const LogBuffer = struct {
    terms: [PARTITION_COUNT][]u8,
    meta_raw: []u8,
    term_length: i32,
    allocator: std.mem.Allocator,
};
```

`init` validates the term length, allocates the metadata buffer, then allocates three term buffers:

```zig
pub fn init(allocator: std.mem.Allocator, term_length: i32) !LogBuffer {
    if (term_length < TERM_MIN_LENGTH or term_length > TERM_MAX_LENGTH)
        return error.InvalidTermLength;
    if ((term_length & (term_length - 1)) != 0)
        return error.TermLengthNotPowerOfTwo;
    ...
}
```

`termBuffer(partition)` returns a mutable slice into the chosen term:

```zig
pub fn termBuffer(self: *const LogBuffer, partition: usize) []u8 {
    if (partition >= PARTITION_COUNT) return &[_]u8{};
    return self.terms[partition];
}
```

Callers compute `partition = active_term_count % PARTITION_COUNT` and receive a raw slice. There is no copy; the term appender writes directly into this memory.

## mmap Instead of malloc

In production Aeron, log buffers are backed by memory-mapped files — either anonymous mappings or file-backed ones shared with the driver. The reasons are:

1. **Persistence across crashes**: a file-backed log can be inspected post-mortem.
2. **Zero-copy IPC**: publisher and subscriber in different processes map the same file; the kernel shares physical pages between them.
3. **Large contiguous regions**: `mmap` can reserve multi-gigabyte address space without committing physical pages upfront.

In Zig, anonymous mmap:

```zig
const term = try std.posix.mmap(
    null,
    @intCast(term_length),
    std.posix.PROT.READ | std.posix.PROT.WRITE,
    .{ .TYPE = .SHARED, .ANONYMOUS = true },
    -1,
    0,
);
```

The current implementation in `log_buffer.zig` uses `allocator.alloc` for simplicity. The mmap path will be added when the driver's file-mapping layer is implemented (driver phase). The `LogBuffer` struct's slice-based interface is designed to be compatible with either backing — a slice over mmap'd memory is indistinguishable from a slice over heap memory.

## Slice Views Over Raw Memory

Zig slices are a `(pointer, length)` pair. When the log buffer maps a large byte array, term buffers are slice views into subregions — no separate allocation, no copy:

```zig
// Hypothetical mmap-backed version:
const full_map: []u8 = mmap_result[0..total_size];
terms[0] = full_map[0..term_length];
terms[1] = full_map[term_length .. 2 * term_length];
terms[2] = full_map[2 * term_length .. 3 * term_length];
meta_raw  = full_map[3 * term_length ..];
```

This is the same pattern Java uses with `ByteBuffer.slice()`, but without the object overhead. Frame reads and writes go through direct pointer arithmetic on these slices, with Zig's bounds checking in debug mode providing safety assertions.

## Key Files

- `src/logbuffer/log_buffer.zig` — `LogBuffer`, `PARTITION_COUNT`, `TERM_MIN_LENGTH`, `TERM_MAX_LENGTH`
- `src/logbuffer/metadata.zig` — `LogBufferMetadata`, tail counter layout, `LOG_META_DATA_LENGTH`, `CACHE_LINE_LENGTH`
