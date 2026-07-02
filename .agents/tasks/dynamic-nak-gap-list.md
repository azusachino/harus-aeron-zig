# Task: Replace fixed NAK gap list with dynamic ArrayList

## Context

`NakState` in `src/driver/receiver.zig` uses `gap_list: [16]GapRange` — a fixed array. When full, new gaps are silently dropped, causing data loss under high packet loss.

## What to do

1. Read `src/driver/receiver.zig` — find the `NakState` struct (~line 171)
2. Replace `gap_list: [16]GapRange = undefined` and `gap_list_len: usize = 0` with `std.ArrayList(GapRange)` or `std.ArrayListUnmanaged(GapRange)`
3. Add `init(allocator, stream_id)` and `deinit()` functions
4. Update `addGap` to use `gap_list.append()` instead of fixed-size check
5. Update all reads of `gap_list_len` → `gap_list.items.len`
6. Update all reads of `gap_list[i]` → `gap_list.items[i]`
7. Find where `NakState` is created in the receiver — update to call `init()` with allocator
8. Find cleanup/destroy paths — add `deinit()` calls
9. Keep existing gap merging logic intact

## Files to modify

- `src/driver/receiver.zig`

## Success criteria

- `make check` passes
- NAK gap list can hold more than 16 gaps
- No silent data loss when gap count exceeds 16
