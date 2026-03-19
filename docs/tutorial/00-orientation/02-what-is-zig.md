# What Is Zig?

Zig is a systems programming language that occupies the same space as C: manual memory
management, direct hardware access, no runtime, no garbage collector. Where it improves on C
is in safety, ergonomics, and — most relevantly for this project — `comptime`, a
first-class mechanism for compile-time computation that replaces preprocessor macros and
C++ templates.

You do not need prior Zig experience. This chapter translates Zig concepts into the mental
models you already have.

## Zig's Core Philosophy

Three rules govern almost every language decision:

1. **No hidden control flow.** There are no C++ constructors that run invisibly, no
   implicit conversions that call user code, no exceptions that unwind the stack without
   a visible `try`. If something might fail, the type says so.
2. **No hidden allocations.** A function that allocates heap memory must receive an
   `Allocator` argument. If you call a function and it takes no allocator, it will not
   allocate. This makes allocation visible and testable.
3. **Comptime over macros.** Instead of the C preprocessor or C++ templates, Zig has
   `comptime` expressions and `comptime` function parameters. Types are values; generic
   code is ordinary Zig code evaluated at compile time.

## For C Engineers

Zig is close to C. The main differences you will encounter:

- **Error unions** instead of returning `-1` and checking `errno`. A function returning
  `!usize` returns either a `usize` or an error. You handle it with `try` (propagate)
  or `catch` (handle locally).
- **`errdefer`** for cleanup. Where C needs `goto cleanup`, Zig has `errdefer`, which
  runs a statement only if the enclosing scope returns an error.
- **`extern struct`** maps directly to a C struct layout. We use it for every Aeron wire
  type so the compiler never inserts padding.
- **No implicit integer promotion.** You must cast explicitly: `@intCast(x)`.
- **`comptime` assertions** replace `static_assert`. We verify every frame struct is
  exactly the right size at compile time:

```zig
const DataHeader = extern struct {
    frame_length: i32,
    version: u8,
    flags: u8,
    frame_type: u16,
    term_offset: i32,
    session_id: i32,
    stream_id: i32,
    term_id: i32,
};
comptime { std.debug.assert(@sizeOf(DataHeader) == 32); }
```

## For Rust Engineers

Zig has no borrow checker. Memory safety comes from discipline, not the type system.
In exchange, you get simpler code and no lifetime annotations.

- **No `Arc`/`Rc`**, no reference counting. Own your memory, free it explicitly.
- **`errdefer`** is the Zig equivalent of RAII + `Drop`. Acquire a resource, then
  immediately write `errdefer resource.deinit()`. If the function returns an error
  later, cleanup runs automatically.
- **`std.atomic.Value(T)`** is the equivalent of `AtomicUsize`. We use it for the
  term tail counters that publishers race to advance.
- **No `unsafe` keyword.** Zig has `@ptrCast` and `@alignCast` for pointer coercions.
  These are not hidden — they are explicit calls you can grep for.
- **Tagged unions** instead of Rust enums with data. `switch` on a tagged union is
  exhaustive by default.

## For Go Engineers

- **No garbage collector.** Every allocation has an explicit owner. Use `defer
  allocator.free(buf)` the same way you use `defer` in Go, but you must match every
  alloc with a free.
- **`std.ArrayList`** is the equivalent of a Go slice. Unlike Go, `append` is
  `ArrayList.append(allocator, item)` — the allocator is passed at the call site,
  not stored inside the list.
- **No goroutines.** Concurrency uses `std.Thread`. The Aeron driver has three threads
  (Conductor, Sender, Receiver); communication between them is via lock-free ring buffers
  and atomic counters.
- **No `interface{}`** (mostly). Where Go uses `interface{}`, Zig uses `*anyopaque`
  (an untyped pointer) combined with a function pointer. We use this pattern for fragment
  handler callbacks.

## For Java Engineers

- **No JVM, no GC pause.** The process is a native binary. Startup time is
  milliseconds, not seconds.
- **Value types everywhere.** A `struct` lives on the stack or inline in its parent.
  There is no boxing. `extern struct` gives you a guarantee equivalent to Java's
  `@StructLayoutKind.Sequential`.
- **No exceptions.** The equivalent of a checked exception is a function that returns
  an error union: `fn parse(buf: []const u8) !Frame`. Callers must handle it.
- **No `null` on references by default.** Nullable pointers are written `?*T` — you
  must unwrap them before use.

## Key Zig Concepts Used in This Codebase

| Concept | Where we use it |
|---------|----------------|
| `extern struct` | Every wire-protocol frame type |
| `comptime @sizeOf` assertions | Size verification of all frame structs |
| `std.atomic.Value(i64)` | Term tail counters |
| Error unions (`!T`) | All fallible functions |
| `errdefer` | Resource cleanup in driver init |
| `*anyopaque` + fn pointer | Fragment handler callbacks |
| `std.Thread` | Conductor, Sender, Receiver threads |
| `std.posix.mmap` | Log buffer and IPC region allocation |

## Common Gotchas

- **`ArrayList.append` takes an allocator**: `list.append(allocator, item)` — not
  `list.append(item)` as you might expect.
- **Integer overflow is safety-checked in debug, wrapping in release.** Use
  `+%` / `-%` / `*%` for explicit wrapping arithmetic.
- **`@alignCast` is required when casting `*anyopaque` to a typed pointer.** Forgetting
  it will compile but may panic at runtime in safe modes.
- **`std.mem.alignForward`** is the right way to pad a length to an alignment boundary.
  Do not write `(n + align - 1) & ~(align - 1)` by hand.
- **`defer` runs at scope exit, even on early return.** `errdefer` runs only on error
  return. Use `defer` for unconditional cleanup, `errdefer` for rollback on failure.
