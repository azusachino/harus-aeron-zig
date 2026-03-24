# Chapter 2.3: UDP Transport

This chapter covers the network transport layer of Aeron. While Aeron is famous for its shared-memory IPC, its primary role is providing reliable messaging over unreliable UDP.

## The Problem

UDP is "fire and forget" — packets can be lost, reordered, or duplicated. Aeron needs a way to turn this chaotic stream into a reliable, ordered sequence of messages while maintaining the low-latency benefits of UDP.

---

## Zig Track: The `std.posix` Socket API

In Zig, network programming is explicit and close to the OS. We don't use a high-level "Socket" class with hidden state; we use raw file descriptors and syscall wrappers.

### Non-blocking Sockets

Aeron's media driver never blocks on I/O. Every socket is opened with the `SOCK.NONBLOCK` flag.

```zig
// LESSON(transport/zig): SOCK_NONBLOCK avoids a separate fcntl() call.
const sock = try std.posix.socket(
    family,
    std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK,
    std.posix.IPPROTO.UDP,
);
```

On Linux, this sets the flag atomically during socket creation. On macOS, Zig's `std.posix` helper transparently handles the `FIONBIO` ioctl if needed. When a non-blocking `recvfrom` has no data, it returns `error.WouldBlock`.

### Multicast Group Join

Receiving multicast requires telling the OS which group we want to join. This involves the `IP_ADD_MEMBERSHIP` socket option.

```zig
const mreq = IpMreq{
    .imr_multiaddr = group.in.sa.addr,
    .imr_interface = interface_addr.in.sa.addr,
};
try std.posix.setsockopt(self.socket, std.posix.IPPROTO.IP, IP_ADD_MEMBERSHIP, &std.mem.toBytes(mreq));
```

Because these constants and structs vary by operating system, `harus-aeron-zig` defines them in `src/transport/endpoint.zig` to ensure cross-platform compatibility where `std.posix` might be missing them.

---

## Aeron Track: Handshakes and Flow Control

Aeron doesn't use TCP-style connections, but it still needs to establish state between a sender and a receiver.

### The SETUP/STATUS Handshake

When a publication starts sending, it periodically broadcasts a **SETUP** frame. This frame contains the `session_id`, `initial_term_id`, and `term_length`.

1. **Sender** sends SETUP until it receives a STATUS frame.
2. **Receiver** sees the SETUP, allocates a local **Image** (including log buffers), and starts sending **STATUS** frames back.
3. **STATUS** frames contain the `receiver_window_address` — this tells the sender how much data it is allowed to send before hitting back-pressure.

### NAK Retransmit Flow

If the receiver detects a gap in the sequence numbers (term offsets), it doesn't immediately ask for a retransmit. It waits for a short duration (default 1ms) to allow for out-of-order packets to arrive.

If the gap persists, it sends a **NAK** (Negative Acknowledgement) frame. The sender, upon receiving a NAK, scans its log buffer and re-sends the missing range of data.

### Unicast vs Multicast URIs

Aeron URIs encode the transport configuration:

- **Unicast**: `aeron:udp?endpoint=192.168.1.10:40123`
- **Multicast**: `aeron:udp?endpoint=224.0.1.1:40456|interface=192.168.1.20`

The driver automatically detects multicast by checking if the endpoint address is in the `224.0.0.0/4` range. For multicast, the `interface` parameter is critical — it tells the OS which physical network card to use for the group join.

---

## Implementation Walkthrough

- **`src/transport/uri.zig`**: Parses the `aeron:udp?...` string into key-value pairs.
- **`src/transport/udp_channel.zig`**: Resolves hostnames and determines if the channel is multicast.
- **`src/transport/endpoint.zig`**: Manages the lifecycle of the `std.posix` socket.
- **`src/transport/poller.zig`**: Uses `std.posix.poll` to multiplex many receive endpoints in a single duty cycle.

## Exercise

1. Open `tutorial/transport/udp_channel.zig` and implement the `isMulticastAddress` helper.
2. Verify with `make tutorial-check`.

Further reading: [Aeron UDP Protocol](https://github.com/aeron-io/aeron/wiki/Protocol-Specification)
