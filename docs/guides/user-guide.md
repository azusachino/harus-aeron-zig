# User Guide

This guide explains how to use `harus-aeron-zig` as a client library in your Zig applications, how to configure and run the Media Driver, and how to use the built-in diagnostic tools.

---

## 1. Using harus-aeron-zig in Your Zig Project

To use this library in your own project, add it to your `build.zig.zon` and import it in `build.zig`.

### build.zig.zon
```zig
.{
    .name = .my_aeron_app,
    .version = "0.1.0",
    .dependencies = .{
        .harus_aeron_zig = .{
            .url = "https://github.com/azusachino/harus-aeron-zig/archive/refs/tags/v0.9.0.tar.gz",
            // Or use a local path dependency for development:
            // .path = "../harus-aeron-zig",
        },
    },
}
```

### build.zig
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Import harus-aeron-zig dependency
    const aeron_dep = b.dependency("harus_aeron_zig", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("aeron", aeron_dep.module("aeron"));
    
    // The driver and diagnostics require linking libc
    exe.linkLibC();

    b.installArtifact(exe);
}
```

---

## 2. Writing a Client Application

Here is a simple example showing how to initialize the client, publish messages, and subscribe to a stream.

### Subscriber Example (`src/sub.zig`)
```zig
const std = @import("std");
const aeron = @import("aeron");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Aeron Client Context
    var ctx = aeron.Context.init(allocator);
    defer ctx.deinit();

    // Connect to the Media Driver
    var client = try aeron.Aeron.connect(allocator, &ctx);
    defer client.deinit();

    const channel = "aeron:udp?endpoint=localhost:40123";
    const stream_id = 1001;

    // Add Subscription
    var subscription = try client.addSubscription(channel, stream_id);
    defer subscription.deinit();

    std.log.info("Subscribed to {s} stream {d}", .{ channel, stream_id });

    // Poll for messages in a loop
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_bytes = try subscription.poll(&buffer);
        if (read_bytes > 0) {
            std.log.info("Received message: {s}", .{buffer[0..read_bytes]});
        }
        std.time.sleep(10 * std.time.ns_per_ms); // Poll rate limiter
    }
}
```

### Publisher Example (`src/pub.zig`)
```zig
const std = @import("std");
const aeron = @import("aeron");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Aeron Client Context
    var ctx = aeron.Context.init(allocator);
    defer ctx.deinit();

    // Connect to the Media Driver
    var client = try aeron.Aeron.connect(allocator, &ctx);
    defer client.deinit();

    const channel = "aeron:udp?endpoint=localhost:40123";
    const stream_id = 1001;

    // Add Publication
    var publication = try client.addPublication(channel, stream_id);
    defer publication.deinit();

    std.log.info("Publishing to {s} stream {d}", .{ channel, stream_id });

    // Send a message
    const msg = "Hello from Zig!";
    while (true) {
        const result = try publication.offer(msg);
        if (result > 0) {
            std.log.info("Message sent successfully!", .{});
            break;
        } else if (result == -1) {
            std.log.warn("Back-pressured, retrying...", .{});
        }
        std.time.sleep(10 * std.time.ns_per_ms);
    }
}
```

---

## 3. Running the Media Driver

The Media Driver orchestrates the UDP transmission and memory-mapped IPC buffers. To start the driver:

```bash
# Run via nix development shell
nix develop --command make run

# Or run the built binary directly
./zig-out/bin/aeron-driver
```

### Driver Configuration Options
You can configure the media driver using command line arguments:
```bash
./zig-out/bin/aeron-driver \
  --aeron-dir /dev/shm/aeron \
  --term-buffer-length 1048576 \
  --mtu-length 1408 \
  --idle-strategy default
```

Available idle strategies:
* `default` — backs off dynamically to conserve CPU.
* `busy` — spins in a hot loop for ultra-low latency (high CPU usage).
* `yield` — yields execution to the OS scheduler.
* `sleep` — sleeps for 1ms on each idle cycle.

---

## 4. CnC Diagnostic Tools

Aeron records metadata, system statistics, and errors into a control-and-command file (`cnc.dat`). The repository builds command line utilities to inspect this file:

### aeron-stat (System Statistics)
Displays active publishers, subscribers, stream positions, and round-trip times.
```bash
./zig-out/bin/aeron-stat
```

### aeron-errors (Error Logs)
Prints driver errors, packet drops, or network socket failures.
```bash
./zig-out/bin/aeron-errors
```

### aeron-loss (Loss Report)
Displays packet loss metrics and NAK retransmissions.
```bash
./zig-out/bin/aeron-loss
```
