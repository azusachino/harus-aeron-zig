# 4.3 Integration Tests

Unit tests verify individual components in isolation. The integration test proves the complete round-trip: a message written through `ExclusivePublication.offer` arrives at a `Subscription.poll` handler in the same process. This chapter walks through the test infrastructure and the test itself.

## What the test proves

`test/integration_test.zig` exercises the full client-library data path without a real network:

1. A `TestHarness` creates an in-process `MediaDriver` and a shared `LogBuffer`.
2. `createPublication` wires an `ExclusivePublication` to that buffer.
3. `createSubscription` creates a `Subscription` backed by an `Image` reading from the same buffer.
4. `offer("hello")` writes a framed message into the term buffer.
5. `doWorkLoop` polls the subscription until the handler fires, or times out.

No sockets. No threads. The publisher and subscriber share the same `LogBuffer` pointer, which is exactly how the IPC transport works in production — the difference is that in production the buffer lives in a memory-mapped file.

## The test harness (test/harness.zig)

`TestHarness` is an embedded driver fixture that short-circuits the IPC channel setup:

```zig
pub const TestHarness = struct {
    allocator: std.mem.Allocator,
    driver: MediaDriver,
    log_buffers: std.ArrayList(*LogBuffer),
    images: std.ArrayList(*Image),
};
```

### init / deinit

`init` creates a `MediaDriver` with default context — in tests this does nothing beyond reserving the struct. `deinit` frees every `Image` and `LogBuffer` allocated during the test.

### createPublication

```zig
pub fn createPublication(self: *TestHarness, stream_id: i32, channel: []const u8) !ExclusivePublication
```

1. Allocates a `LogBuffer` on the heap (64 KiB terms) and appends it to `self.log_buffers`.
2. Initialises the log buffer metadata: `raw_tail = initial_term_id << 32`, `active_term_count = 0`.
3. Constructs an `ExclusivePublication` with `initial_term_id = 100` and MTU 1408.
4. Sets `publisher_limit = 1 MiB` — bypasses flow control for the test.

The `channel` argument is accepted but ignored; the harness wires up IPC directly.

### createSubscription

```zig
pub fn createSubscription(self: *TestHarness, stream_id: i32, channel: []const u8) !Subscription
```

If the harness has at least one `LogBuffer`, it allocates an `Image` pointing to the most recently created buffer and calls `sub.addImage`. Publication and subscription now share one buffer — writes by `offer` are immediately visible to `poll`.

### doWorkLoop

```zig
pub fn doWorkLoop(
    self: *TestHarness,
    sub: *Subscription,
    ctx: *anyopaque,
    handler: FragmentHandler,
    expected: i32,
    timeout_ms: u64,
) !void
```

Loops until the fragment count in `ctx` reaches `expected` or the monotonic timer exceeds `timeout_ms`. Each iteration:

1. Calls `self.driver.doWork()` — a no-op stub in the test build.
2. Calls `sub.poll(handler, ctx, 10)`.
3. Sleeps 1 ms if `poll` returned zero (avoids busy-spinning in CI).

Returns `error.Timeout` if the deadline is reached before `expected` fragments arrive.

## Annotated walkthrough: integration_test.zig

```zig
const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

test "round-trip 1 message" {
```

Zig test blocks are anonymous declarations. `std.testing` provides the assertion functions. The test runner collects all `test` blocks in files referenced from `build.zig`.

```zig
    const allocator = testing.allocator;
    var h = try harness.TestHarness.init(allocator);
    defer h.deinit();
```

`testing.allocator` is a `std.heap.GeneralPurposeAllocator` wrapped to detect leaks. At the end of each test it reports any allocation that was not freed — no valgrind needed. `defer` runs `deinit` whether the test passes or returns an error.

```zig
    const stream_id: i32 = 1001;
    const channel = "aeron:ipc";

    var pub_instance = try h.createPublication(stream_id, channel);
    defer pub_instance.close();

    var sub = try h.createSubscription(stream_id, channel);
    defer sub.deinit();
```

Both the publication and subscription share the same in-memory log buffer created inside `createPublication`. The `channel` string is `"aeron:ipc"` by convention; the harness ignores it.

```zig
    var received_count: i32 = 0;

    const handler = struct {
        fn handle(header: *const @import("aeron").protocol.DataHeader,
                  data: []const u8, ctx: *anyopaque) void {
            _ = header;
            _ = data;
            const count_ptr = @as(*i32, @ptrCast(@alignCast(ctx)));
            count_ptr.* += 1;
        }
    }.handle;
```

The fragment handler is defined as a comptime-anonymous struct with a single `fn`. This is the Zig pattern for a named function that has no global name — `handler` holds a function pointer, not a closure. The `ctx` cast is the standard `*anyopaque` → `*i32` pattern.

```zig
    const msg = "hello";
    const result = pub_instance.offer(msg);
    try testing.expect(result == .ok);
```

`testing.expect` is the equivalent of `assert`. It returns `error.TestUnexpectedResult` on failure, which the `try` propagates to the test runner. The `.ok` comparison on a tagged union works because Zig generates equality for tag-only comparison — it does not compare the payload here, only the active tag.

```zig
    try h.doWorkLoop(&sub, &received_count, handler, 1, 1000);
    try testing.expectEqual(@as(i32, 1), received_count);
}
```

`expectEqual` checks value equality and prints both sides on failure. The `@as(i32, 1)` cast makes the types match — Zig's type inference does not widen integers silently.

## std.testing in Zig

| Function | Use |
|---|---|
| `testing.allocator` | Leak-detecting allocator for test scope |
| `testing.expect(b)` | Assert boolean |
| `testing.expectEqual(a, b)` | Assert equality with type check |
| `testing.expectEqualSlices(T, a, b)` | Assert slice contents |
| `testing.expectError(e, expr)` | Assert an expression returns a specific error |

## Adding more tests

### Boundary cases

- Offer a message exactly at the term boundary (offset = term_length - frame_alignment).
- Set `publisher_limit = 0` and confirm `offer` returns `.back_pressure`.
- Call `close()` then `offer()` and confirm `.closed`.

### Property-based patterns

Zig does not have a built-in property testing library, but you can loop over generated inputs:

```zig
test "offer accepts any payload up to MTU" {
    var rng = std.Random.DefaultPrng.init(0);
    for (0..100) |_| {
        const len = rng.random().intRangeLessThan(usize, 1, 1408);
        var buf: [1408]u8 = undefined;
        rng.random().bytes(buf[0..len]);
        // ... offer and verify
    }
}
```

### Multi-message sequencing

Add a second `offer` call and assert `received_count == 2`. Verify that the second message's position equals the first position plus the aligned frame length.

## Wire compatibility testing against real Java Aeron

The setup in `docs/setup.md` describes a Docker-based approach:

1. Pull the official `aeronmd` Docker image.
2. Start it with a shared `aeron_dir` volume mounted at `/dev/shm/aeron`.
3. Run the Zig media driver against the same `aeron_dir`.
4. Use the Java `AeronStat` or `BasicPublisher` / `BasicSubscriber` samples to send/receive.

The test passes when a message published from Java is received by the Zig subscription handler, and vice versa. This verifies frame encoding, flow-control counter placement, and log buffer metadata layout against the reference implementation. Run this before any `v1.0` release tag per the release rules.
