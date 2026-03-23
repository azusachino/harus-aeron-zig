# Chapter 3.3: The Conductor and CnC.dat

The Conductor is the "brain" of the Media Driver. It doesn't touch the data path (sending or receiving packets); instead, it manages the lifecycle of resources and coordinates between clients and the other driver agents.

## The Problem

How do multiple independent processes (the Driver and many Clients) coordinate without a central broker or heavy RPC? How does a client "connect" to a driver that might have started at any time?

---

## Zig Track: Shared Memory via `mmap`

Aeron uses the file system as a rendezvous point. Processes communicate by mapping the same file into their respective virtual address spaces.

### The `std.posix.mmap` API

In Zig, we use `std.posix.mmap` to request the OS to map a file descriptor to a memory address.

```zig
// LESSON(conductor/zig): We mmap a file and cast a pointer to our header struct.
const ptr = try std.posix.mmap(
    null,
    total_size,
    std.posix.PROT.READ | std.posix.PROT.WRITE,
    .{ .TYPE = .SHARED },
    file.handle,
    0,
);
const mapped = @as([*]align(std.heap.page_size_min) u8, @ptrCast(ptr))[0..total_size];
```

The `.TYPE = .SHARED` flag is critical: it ensures that writes to this memory are visible to other processes mapping the same file.

### Pointer Arithmetic in Mapped Memory

Once mapped, we treat the file as a large byte array. We use offsets to locate specific buffers (ring buffers, broadcast buffers, counters) within the single `CnC.dat` file.

```zig
pub fn toDriverBuffer(self: *CncFile) []u8 {
    const len = @as(usize, @intCast(self.toDriverBufferLength()));
    return self.mapped[CNC_HEADER_SIZE..][0..len];
}
```

Zig's slice syntax `mapped[start..][0..len]` provides a safe way to create views into the shared memory without manual pointer incrementing.

---

## Aeron Track: Driver Discovery and Resource Lifecycle

### CnC.dat: The Command and Control File

The `CnC.dat` file is the first thing an Aeron client looks for. It lives in the `aeron.dir` (often `/dev/shm/aeron` on Linux for maximum speed).

The file contains:
1. **The Header**: Version, magic number, and lengths of all following buffers.
2. **To-Driver Ring Buffer**: Clients write commands here (e.g., "Add Publication").
3. **To-Clients Broadcast Buffer**: Driver writes events here (e.g., "Publication Ready").
4. **Counters Metadata & Values**: Shared statistics and positions.

### Client Handshake

When you call `Aeron.connect()`, the client:
1. Finds `CnC.dat` in the configured directory.
2. Maps it into memory.
3. Reads the versions to ensure compatibility.
4. Starts a "Keepalive" heartbeat so the driver knows the client is still alive.

### Resource Lifecycle

The Conductor manages the lifecycle of Publications and Subscriptions. 
- When a client asks for a **Publication**, the Conductor allocates a new `session_id`, creates the log buffer files on disk, and notifies the client via the broadcast buffer.
- If a client crashes, its keepalive will stop. The Conductor detects this and eventually cleans up the associated resources (closing log buffers, reclaiming session IDs).

---

## Implementation Walkthrough

- **`src/driver/cnc.zig`**: Implements the driver-side creation and layout of the `CnC.dat` file.
- **`src/cnc.zig`**: Implements the client-side mapping and reading of `CnC.dat`.
- **`src/driver/conductor.zig`**: The main agent loop. It polls the `to-driver` ring buffer for commands and dispatches them to handlers like `handleAddPublication`.

## Exercise

1. Open `tutorial/driver/conductor.zig` and implement the `handleMessage` dispatcher.
2. Verify that the conductor can process an `ADD_PUBLICATION` command.

Further reading: [Aeron CnC File Descriptor](https://github.com/aeron-io/aeron/blob/master/aeron-client/src/main/java/io/aeron/CncFileDescriptor.java)
