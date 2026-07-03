# Zig Module System

How Zig manages multiple logical libraries within one repo — the equivalent of
Rust's workspace + crates.

## Core Mechanism

Zig has no per-module manifest. Everything is declared in the root `build.zig`
using `b.addModule()`. Source files just use `@import("name")` and the build
wires up what that name resolves to.

```zig
// build.zig
const agrona = b.addModule("agrona", .{
    .root_source_file = b.path("lib/agrona/root.zig"),
});

const driver = b.addModule("driver", .{
    .root_source_file = b.path("src/driver/driver.zig"),
    .imports = &.{
        .{ .name = "agrona", .module = agrona },
    },
});

// Wire into an executable or test step:
exe.root_module.addImport("agrona", agrona);
exe.root_module.addImport("driver", driver);
```

Usage in source:
```zig
const agrona = @import("agrona");
const RingBuffer = agrona.ManyToOneRingBuffer;
```

## Comparison: Rust vs Zig

| Concept | Rust | Zig |
|---------|------|-----|
| Multi-library project | Cargo workspace | `build.zig` with named modules |
| Per-library manifest | `Cargo.toml` per crate | none — single `build.zig` |
| Library root | `lib.rs` | `root_source_file` in `addModule` |
| Dependency declaration | `[dependencies]` in `Cargo.toml` | `addImport` in `build.zig` |
| External packages | `Cargo.lock` + crates.io | `build.zig.zon` + package URLs |
| Visibility boundary | crate boundary enforces privacy | none — `pub` is per-declaration |

## Key Differences from Rust

**No hard encapsulation boundary.** Rust's crate boundary enforces visibility — `pub`
inside a crate is invisible outside without `pub use`. Zig modules have no such
enforcement: `pub` means public, full stop. You get logical separation but not
compiler-enforced encapsulation.

**No implicit re-exports.** In Rust you `pub use sub::Thing` to flatten a module
tree. In Zig the conventional pattern is:

```zig
// lib/agrona/root.zig
pub const ManyToOneRingBuffer = @import("ring_buffer.zig").ManyToOneRingBuffer;
pub const BroadcastTransmitter = @import("broadcast.zig").BroadcastTransmitter;
pub const CountersManager = @import("counters.zig").CountersManager;
```

**Dependency is declared in build, not in source.** The source file never knows
where `@import("agrona")` comes from — that mapping lives in `build.zig`. This
makes refactoring module layout transparent to source code.

## Recommended Layout for This Project

```
harus-aeron-zig/
├── lib/
│   └── agrona/              ← standalone Agrona primitives module
│       ├── root.zig         ← re-exports all public types
│       ├── ring_buffer.zig  ← ManyToOneRingBuffer
│       ├── broadcast.zig    ← BroadcastTransmitter / BroadcastReceiver
│       ├── counters.zig     ← CountersManager
│       └── idle_strategy.zig
├── src/
│   ├── driver/              ← imports "agrona"
│   ├── archive/             ← imports "agrona"
│   └── cluster/             ← imports "agrona"
└── build.zig                ← declares agrona module, wires imports
```

This matches the pattern used by `libxev`, `zig-sqlite`, and `zml`.

## External Packages (build.zig.zon)

For packages consumed from outside the repo, `build.zig.zon` is the equivalent
of `Cargo.toml` dependencies:

```zon
.dependencies = .{
    .agrona = .{
        .url = "https://...",
        .hash = "...",
    },
},
```

Each external package can expose one or more named modules via its own `build.zig`.
The consumer wires them in the same way as local modules.
