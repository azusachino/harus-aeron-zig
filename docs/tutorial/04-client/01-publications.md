# 4.1 Publications

`ExclusivePublication` is the user-facing write API. If you have sent a message over Aeron, you called `offer`. This chapter walks through what happens between that call and bytes landing in the log buffer.

## Role

A publication is a handle to one (channel, stream_id) pair opened exclusively by a single writer. "Exclusive" means no CAS contention: only this thread appends to the active term. The trade-off is that you cannot share an `ExclusivePublication` across threads without external synchronisation.

The publication does not own a socket. That is the Sender Agent's job. The publication's only job is to write a correctly framed message into the log buffer at the right offset and return a new stream position.

## OfferResult: sentinel enum returns instead of error unions

```zig
pub const OfferResult = union(enum) {
    ok: i64,           // new stream position after this message
    back_pressure,     // publisher limit reached — retry later
    not_connected,     // no active subscribers yet
    admin_action,      // term rotation in progress — retry immediately
    closed,
    max_position_exceeded,
};
```

Zig error unions (`!T`) are for failures the caller cannot recover from inline — allocation failure, I/O error, invalid input. Back-pressure is not a failure: it is expected steady-state behaviour in a fast publisher / slow consumer scenario. Encoding it as a tagged union value keeps call sites explicit and forces the caller to handle every case, without paying for the unwinding machinery that error propagation implies.

Compare to the Java API, which returns negative `long` sentinel values (`NOT_CONNECTED = -1`, `BACK_PRESSURED = -2`, etc.). The Zig union gives the same information with compiler-enforced exhaustive matching.

## The offer() flow

```zig
pub fn offer(self: *ExclusivePublication, data: []const u8) OfferResult {
    if (self.is_closed) return .closed;

    const raw_tail = self.appender.rawTailVolatile();
    const term_id     = @as(i32, @intCast(raw_tail >> 32));
    const term_offset = @as(i32, @intCast(raw_tail & 0xFFFF_FFFF));
    const current_position = @as(i64, term_id - self.initial_term_id)
        * self.term_length + term_offset;

    if (current_position >= self.publisher_limit) {
        return .back_pressure;
    }
    // ... build DataHeader, delegate to TermAppender.appendUnfragmented
}
```

Three checks happen before a byte is written:

1. **Closed guard** — if `close()` was called, return immediately.
2. **Current position** — derived from the raw tail word packed in the log buffer metadata. The upper 32 bits are the term ID; the lower 32 bits are the byte offset within that term.
3. **Publisher limit** — a flow-control ceiling set by the Sender Agent via a shared counter. If `current_position >= publisher_limit`, the receiver window is full; return `back_pressure`.

Once those checks pass, `offer` constructs a `DataHeader` with `BEGIN_FLAG | END_FLAG` (single-frame message) and delegates to `TermAppender.appendUnfragmented`, which copies the header and payload into the term buffer and advances the tail atomically.

The return value from `TermAppender` maps to `OfferResult`:

| Appender result   | OfferResult         |
|-------------------|---------------------|
| `appended`        | `.ok(new_position)` |
| `tripped`         | `.back_pressure`    |
| `admin_action`    | `.admin_action`     |
| `padding_applied` | `.admin_action`     |

## isConnected()

```zig
pub fn isConnected(self: *const ExclusivePublication) bool {
    // In full implementation: check sender position counter > -1
    return !self.is_closed;
}
```

In the complete driver integration, `isConnected` reads a per-publication counter written by the Sender Agent. When the Sender has at least one subscriber's receiver window it is tracking, it sets the counter. Polling that counter avoids a round-trip to the driver. The stub above returns `!is_closed` until the counter plumbing is complete.

## Handling back_pressure

Back-pressure is the normal signal that your publisher is faster than the network path or the consumer. The correct response is to retry without allocating:

```zig
while (true) {
    switch (pub.offer(msg)) {
        .ok => |pos| { _ = pos; break; },
        .back_pressure, .admin_action => {
            // yield or sleep briefly, then retry
            std.Thread.sleep(1 * std.time.ns_per_us);
        },
        .not_connected => return error.NoSubscribers,
        .closed, .max_position_exceeded => return error.PublicationDead,
    }
}
```

Never drop messages silently. The `switch` forces you to handle every variant.

## Function reference

| Function | Description |
|---|---|
| `init(session_id, stream_id, initial_term_id, term_length, mtu, log_buffer)` | Construct from log buffer metadata |
| `offer(data) OfferResult` | Write a single-frame message |
| `offerParts(iov) OfferResult` | Vectored write — header + payload as separate slices |
| `position() i64` | Current publication stream position |
| `isConnected() bool` | True if sender is tracking at least one subscriber |
| `close() void` | Mark closed; future `offer` calls return `.closed` |

## Key Zig points

- `@intCast` is checked in Debug builds — it traps if the value does not fit. Use it on the raw tail to catch metadata corruption early.
- `rawTailVolatile` uses `@atomicLoad(.acquire)` so the compiler cannot reorder the position check above the memory load.
- The packed tail word (`term_id << 32 | offset`) is a Zig `i64` interpreted as two `i32` halves. Zig's explicit integer casting makes the intent readable where Java or C would use unchecked bit shifts.
