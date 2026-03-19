# Project Context — harus-aeron-zig

Aeron protocol reimplementation in Zig 0.15.2 — wire-compatible UDP transport.
Reference: https://github.com/aeron-io/aeron

## Stack
- Language: Zig 0.15.2 (nixpkgs unstable)
- Task runner: `make check` (fmt-check + build + test), `make test`, `make build`
- Dev shell: `nix develop` — never install tools globally

## Key conventions
- `extern struct` for all wire-protocol types — layout must match the C/Java reference exactly
- Add `comptime { std.debug.assert(@sizeOf(T) == N); }` for every wire frame type
- Explicit allocator API everywhere: `list.append(allocator, item)`, `list.deinit(allocator)`
- Use `std.atomic.Value(T)` for any counter accessed from multiple threads
- No `unreachable` in receive/decode paths — external data is untrusted
- No mutex in hot paths — use CAS (`cmpxchgStrong`) or atomic fetch-add

## Zig 0.15.2 API gotchas (common mistakes to avoid)
- `allocator.alignedAlloc(u8, 4096, n)` — WRONG: `alignedAlloc` takes `?std.mem.Alignment` enum, not int. Just use `allocator.alloc(u8, n)` unless you truly need specific alignment
- `allocator.alignedFree(buf)` — does NOT exist. Use `allocator.free(buf)` always
- `@mod(i32_val, usize_const)` — type mismatch. Use `@as(usize, @intCast(@abs(i32_val))) % usize_const`
- Ring buffer record length: store actual `HEADER_LENGTH + data.len` in header, advance cursor by `aligned(data.len)` — these are different values
- `i64 align(4)` needed on i64 fields in extern structs where the field is at a non-8-aligned offset (Aeron uses `#pragma pack(4)`)

## Key protocol references
- Frame layouts: `aeron-driver/src/main/c/protocol/aeron_udp_protocol.h`
- Log buffer: `aeron-client/src/main/java/io/aeron/logbuffer/LogBufferDescriptor.java`
- Ring buffer: `aeron-client/src/main/java/org/agrona/concurrent/ringbuffer/ManyToOneRingBuffer.java`
- Counters: `aeron-driver/src/main/java/org/agrona/concurrent/status/CountersMap.java`
- Broadcast: `aeron-client/src/main/java/org/agrona/concurrent/broadcast/`

## File layout
- `src/protocol/frame.zig` — wire frame structs
- `src/logbuffer/` — log buffer, term appender, term reader
- `src/ipc/` — ring buffer, broadcast, counters
- `src/transport/` — UDP channel and endpoint
- `src/driver/` — conductor, sender, receiver, media driver
- `src/aeron.zig` — client library root
- `src/main.zig` — driver binary entry
