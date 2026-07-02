# Zig 0.16 std.Io migration reference

Zig 0.16 moved file I/O out of `std.fs`/`std.posix` into the `std.Io` interface.
Every `File`/`Dir` operation now takes an `io: std.Io` instance as its first
argument (after the receiver). We provide a process-wide instance.

## The Io provider

`src/io.zig` exposes `pub fn io() std.Io`. Import it with the correct relative
path for the file you are editing:

- `src/foo.zig`            -> `@import("io.zig")`
- `src/archive/foo.zig`    -> `@import("../io.zig")`
- `src/driver/foo.zig`     -> `@import("../io.zig")`
- `src/logbuffer/foo.zig`  -> `@import("../io.zig")`
- `src/tools/foo.zig`      -> `@import("../io.zig")`

Convention: `const io_mod = @import("../io.zig");` then pass `io_mod.io()`.

## API mapping (old 0.15 -> new 0.16)

| Old | New |
| --- | --- |
| `std.fs.cwd()` | `std.Io.Dir.cwd()` |
| `std.fs.File` (type) | `std.Io.File` |
| `std.fs.Dir` (type) | `std.Io.Dir` |
| `dir.openFile(path, opts)` | `dir.openFile(io_mod.io(), path, opts)` |
| `std.fs.openFileAbsolute(path, opts)` | `std.Io.Dir.openFileAbsolute(io_mod.io(), path, opts)` |
| `dir.createFile(path, flags)` | `dir.createFile(io_mod.io(), path, flags)` |
| `std.fs.createFileAbsolute(path, flags)` | `std.Io.Dir.createFileAbsolute(io_mod.io(), path, flags)` |
| `dir.makePath(path)` / `makeDirAbsolute` | check `std.Io.Dir` for the 0.16 equivalent (takes `io`) |
| `dir.statFile(path)` | `dir.statFile(io_mod.io(), path, .{})` |
| `dir.deleteFile(path)` | `dir.deleteFile(io_mod.io(), path)` |
| `file.close()` | `file.close(io_mod.io())` |
| `file.sync()` | `file.sync(io_mod.io())` |
| `file.stat()` | `file.stat(io_mod.io())` |
| positional read | `file.readPositionalAll(io_mod.io(), buffer, offset)` |
| positional write | `file.writePositionalAll(io_mod.io(), bytes, offset)` |
| streaming write-all | `file.writeStreamingAll(io_mod.io(), bytes)` |
| `file.reader(buf)` | `file.reader(io_mod.io(), buf)` |
| `file.writer(buf)` | `file.writer(io_mod.io(), buf)` |

## Rules

- Do NOT use raw `std.c.*` / `std.posix.*` file syscalls for open/read/write/
  close/sync/stat/mkdir. Use the `std.Io.File`/`std.Io.Dir` API above. (Earlier
  drafts of catalog.zig / recorder.zig / log_buffer.zig used raw libc — those
  MUST be rewritten to std.Io.)
- EXCEPTION: `std.posix.mmap`/`munmap` still exist in 0.16 and are the right
  tool for the memory-mapped log buffer — keep those as posix.
- Consult the real 0.16 std source when a signature is unclear:
  `/nix/store/4011jw1w9cx2l4qcmml0lmm9jr83l7pi-zig-0.16.0/lib/zig/std/Io/File.zig`
  and `.../Io/Dir.zig`. Do not guess.
- Preserve behavior exactly. Match surrounding code style. Minimal diffs.
- `ArrayListUnmanaged` empty init is now `.empty` (not `.{}`).
