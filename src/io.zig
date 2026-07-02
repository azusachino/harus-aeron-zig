//! Process-wide `std.Io` provider.
//!
//! Zig 0.16 moved file I/O out of `std.fs`/`std.posix` into the `std.Io`
//! interface: every `File`/`Dir` operation takes an `io: std.Io` instance.
//! This module owns a single blocking `std.Io.Threaded` for the whole process
//! and hands it out via `io()`, so callers do not need to thread an `Io`
//! parameter through every signature.
//!
//! The backing allocator is only consulted by `std.Io.Threaded` for the
//! `async`/`concurrent` families (see its `init` docs); we perform only
//! synchronous file I/O, so `page_allocator` is never actually exercised for
//! allocation here — it is a safe, never-failing placeholder.

const std = @import("std");

/// One-time init state: 0 = uninitialized, 1 = initializing, 2 = ready.
/// A lock-free guard rather than a mutex: Zig 0.16's `std.Io.Mutex.lock`
/// itself needs an `Io`, which we cannot supply while bootstrapping it.
var state: std.atomic.Value(u8) = .init(0);
var threaded: std.Io.Threaded = undefined;

/// Return the shared process `std.Io`. Thread-safe and lazily initialized:
/// the media driver spins up sender/receiver/conductor threads that all touch
/// files, so first-use initialization must be guarded.
pub fn io() std.Io {
    if (state.load(.acquire) != 2) {
        if (state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
            threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
            state.store(2, .release);
        } else {
            while (state.load(.acquire) != 2) {} // another thread is initializing
        }
    }
    return threaded.io();
}
