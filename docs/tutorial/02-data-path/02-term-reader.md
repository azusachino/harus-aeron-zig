# 2.2 Term Reader

**Source:** `src/logbuffer/term_reader.zig`
**Concept:** Forward scan of a term partition, dispatching complete frames to a handler
**Zig focus:** Function pointer types, `*anyopaque` context, `std.mem.readInt`

---

## Role

`TermReader` scans a term buffer from a caller-supplied offset, reads committed frames one by one, and invokes a `FragmentHandler` callback for each data frame. It never allocates. It returns a `ReadResult` containing the number of fragments dispatched and the next offset to resume from.

Because the appender writes `frame_length` last, the reader's primary signal is that field: zero means nothing has been committed yet; positive means the frame is complete and safe to read.

---

## The Fragment Handler Type

```zig
pub const FragmentHandler = *const fn (
    header: *const frame.DataHeader,
    buffer: []const u8,
    ctx: *anyopaque,
) void;
```

`FragmentHandler` is a typed function pointer. The `ctx` parameter carries a type-erased context pointer — the Zig equivalent of a closure capture. At the call site the caller casts their concrete state pointer to `*anyopaque`; inside the callback they cast back:

```zig
const handler = struct {
    fn handle(header: *const frame.DataHeader, payload: []const u8, ctx: *anyopaque) void {
        const state = @as(*MyState, @ptrCast(@alignCast(ctx)));
        state.count += 1;
        _ = header; _ = payload;
    }
}.handle;

_ = TermReader.read(term, 0, handler, &my_state, 10);
```

`@alignCast` is required because `*anyopaque` carries no alignment information; `@ptrCast` alone would be a compile error if the target type has an alignment requirement greater than 1.

---

## The Scan Loop

```
         ┌───────────────────────────────────────┐
         │  current_offset = offset              │
         │  fragments_read = 0                   │
         └─────────────────┬─────────────────────┘
                           │
                    ┌──────▼───────┐
              ┌─────┤ fragments <  ├─────┐
              │ no  │  limit?      │ yes │
              ▼     └──────────────┘     ▼
           return                  read frame_length at current_offset
                                        │
                                   <= 0 ┤ positive
                                        ▼
                                   return    compute aligned_len
                                              │
                                         check type
                                              │
                                    padding ──┤── data
                                              │       │
                                          advance   call handler
                                          offset    fragments_read++
                                              │       │
                                              └───┬───┘
                                                  ▼
                                           current_offset += aligned_len
```

The full `read` signature:

```zig
pub fn read(
    term: []const u8,
    offset: i32,
    handler: FragmentHandler,
    ctx: *anyopaque,
    fragments_limit: i32,
) ReadResult
```

`fragments_limit` is a work-budget: the caller (typically the subscription duty cycle) passes a small number like 10 to bound the time spent in a single poll iteration.

Frame length is read with `std.mem.readInt` rather than a pointer cast to remain correct regardless of the platform's native alignment requirements:

```zig
const frame_length = std.mem.readInt(i32, frame_length_bytes[0..4], .little);
```

Similarly, the frame type is read at offset +6 to decide whether to skip (padding) or dispatch (data):

```zig
const frame_type_raw = std.mem.readInt(u16, type_bytes[0..2], .little);
const is_padding = frame_type_raw == @intFromEnum(frame.FrameType.padding);
```

---

## Fragment Flags and Reassembly

`DataHeader.flags` carries three meaningful bits:

| Constant | Value | Meaning |
|----------|-------|---------|
| `BEGIN_FLAG` | `0x80` | First fragment of a message |
| `END_FLAG` | `0x40` | Last fragment of a message |
| Both set | `0xC0` | Unfragmented (fits in one frame) |

A message that fits in a single MTU has both flags set. Larger messages are split by the publication layer: the first frame carries `BEGIN_FLAG` only, middle frames carry neither, and the last frame carries `END_FLAG`. The subscription layer above `TermReader` accumulates slices until it sees `END_FLAG`, then delivers the reassembled message to the application.

`TermReader` itself does not reassemble — it delivers every fragment to the handler individually and trusts the handler (or a wrapper) to manage reassembly state. This keeps the reader free of allocation.

---

## ReadResult

```zig
pub const ReadResult = struct {
    fragments_read: i32,
    offset: i32,
};
```

The returned `offset` is the byte position immediately after the last frame processed. The caller stores this as its subscriber position and passes it back on the next `read` call. If `fragments_read == 0` and `offset == input_offset`, the term has no new data.

---

## Function Reference

| Symbol | Kind | Purpose |
|--------|------|---------|
| `FragmentHandler` | type alias | Function pointer signature for callbacks |
| `ReadResult` | struct | fragments dispatched + next scan offset |
| `TermReader.read` | fn | Core scan loop; no allocation, no state retained |

---

## Next Step

Proceed to **2.3 UDP Transport** (`docs/tutorial/02-data-path/03-udp-transport.md`) to see how frames leave the term buffer and travel over the network.
