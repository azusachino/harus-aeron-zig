# 4.2 Subscriptions

A `Subscription` is the read side of a (channel, stream_id) pair. It does not read from a socket directly; it polls a collection of `Image` objects, each representing one sender's view of the log buffer. This chapter covers the subscription model, the Image concept, and the poll loop.

## The Image concept

When a new sender is discovered on a subscribed channel, the driver creates an `Image` — a read cursor into that sender's log buffer partition. One sender equals one Image. If two publishers write to the same `(channel, stream_id)`, the subscription holds two Images.

```zig
pub const Image = struct {
    session_id: i32,
    stream_id: i32,
    initial_term_id: i32,
    log_buffer: *logbuffer.LogBuffer,
    subscriber_position: i64,
    is_end_of_stream: bool,
    is_closed: bool,
    // ...
};
```

`subscriber_position` is the byte offset this consumer has read up to. It is compared against the publisher's tail to determine how many bytes are available. The driver's Receiver Agent monitors `subscriber_position` values across all subscribers to compute the flow-control window it reports back to senders.

## Subscription struct

```zig
pub const Subscription = struct {
    stream_id: i32,
    channel: []const u8,
    image_list: std.ArrayList(*Image),
    allocator: std.mem.Allocator,
    is_closed: bool,
};
```

`image_list` is a heap-allocated `ArrayList` of `*Image` pointers. The pointer indirection matters: Images are allocated individually and may be added or removed at runtime as senders join and leave.

### `[]Image` vs `[]*Image`

Zig slices are fat pointers: a pointer and a length. `[]Image` would be a slice of Image values — copying them on resize. `[]*Image` is a slice of pointers to Images, which are stable in memory and can be passed to other threads without copying. Use `[]*T` when:

- `T` is large (an Image owns a reference to a log buffer),
- `T` has identity (you compare addresses, not values), or
- `T` must be mutated through the slice without copying back.

The `images()` function returns `[]*Image` — a slice of the internal ArrayList's pointer buffer:

```zig
pub fn images(self: *const Subscription) []*image_mod.Image {
    return self.image_list.items;
}
```

## poll() flow

```zig
pub fn poll(
    self: *Subscription,
    handler: term_reader.FragmentHandler,
    ctx: *anyopaque,
    fragment_limit: i32,
) i32 {
    var total_fragments_read: i32 = 0;
    for (self.image_list.items) |img| {
        if (total_fragments_read >= fragment_limit) break;
        total_fragments_read += img.poll(handler, ctx, fragment_limit - total_fragments_read);
    }
    return total_fragments_read;
}
```

`poll` iterates Images round-robin, calling `img.poll` on each until the fragment budget is exhausted. The return value is the total fragment count across all Images — zero means nothing was available.

Each `img.poll` delegates to `TermReader.read`, which scans the term buffer from `subscriber_position` forward, calling `handler` once per frame, and returns the number of fragments consumed. After `TermReader` returns, the Image advances `subscriber_position` by the bytes consumed, which is visible to the Sender/Receiver agents via shared memory.

`FragmentHandler` is a function pointer type:

```zig
pub const FragmentHandler = *const fn (
    header: *const frame.DataHeader,
    data: []const u8,
    ctx: *anyopaque,
) void;
```

`ctx` is an untyped context pointer — Zig's equivalent of a `void*` closure. The caller casts it to their state struct with `@ptrCast(@alignCast(ctx))`.

## Fragment reassembly

Large messages that exceed the MTU are split across multiple frames by `TermAppender.appendFragmented`. The first frame carries `BEGIN_FLAG`, intermediate frames carry no flag, and the last frame carries `END_FLAG`. `TermReader` detects this sequence and reassembles fragments before invoking the handler with the complete message. The reassembly buffer is held in the Image so it persists across `poll` calls.

At this stage the implementation delivers single-frame messages only (`BEGIN_FLAG | END_FLAG`). Multi-frame reassembly is plumbed but not yet exercised in the integration test.

## isConnected()

```zig
pub fn isConnected(self: *const Subscription) bool {
    return self.image_list.items.len > 0;
}
```

A subscription is connected when at least one Image is active. Images are added by the driver conductor when a matching publication is detected and removed when a sender goes idle or disconnects. The subscriber never allocates or frees Images directly.

## Image lifecycle

| Function | Description |
|---|---|
| `Image.init(session_id, stream_id, initial_term_id, log_buffer)` | Construct from log buffer and sender metadata |
| `img.poll(handler, ctx, limit) i32` | Read up to `limit` fragments, invoke handler, advance position |
| `img.position() i64` | Current subscriber read position |
| `img.isEndOfStream() bool` | True after the sender has closed cleanly |
| `img.close() void` | Mark closed; future `poll` calls return 0 |

## addImage / removeImage

```zig
pub fn addImage(self: *Subscription, img: *Image) !void {
    try self.image_list.append(self.allocator, img);
}

pub fn removeImage(self: *Subscription, session_id: i32) void {
    for (self.image_list.items, 0..) |img, i| {
        if (img.session_id == session_id) {
            _ = self.image_list.swapRemove(i);
            return;
        }
    }
}
```

`swapRemove` replaces the removed element with the last element and shrinks the list by one — O(1) with no shifting. Order is not preserved, which is acceptable because there is no defined ordering guarantee between Images.

## Key Zig points

- `std.ArrayList` stores its allocator externally in Zig 0.14+. Pass the allocator to `append`, `deinit`, etc. rather than storing it in the list.
- `*anyopaque` is Zig's type-safe `void*`. You must `@alignCast` before `@ptrCast` to satisfy the alignment checker.
- Fragment handlers must not block. The poll loop is single-threaded; a blocking handler stalls all Images.
