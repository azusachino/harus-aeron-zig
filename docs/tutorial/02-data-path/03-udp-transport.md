# 2.3 UDP Transport

**Sources:** `src/transport/udp_channel.zig`, `src/transport/endpoint.zig`, `src/transport/poller.zig`
**Concept:** Aeron URI parsing, UDP socket lifecycle, multicast group membership, poll multiplexing
**Zig focus:** `std.posix` socket API, `std.net.Address`, `setsockopt`, `std.posix.poll`

---

## Aeron URI Format

Aeron identifies a channel by a URI of the form:

```
aeron:udp?endpoint=localhost:40123
aeron:udp?endpoint=224.0.1.1:40456|interface=192.168.1.10
aeron:ipc
```

The scheme is always `aeron:`. The media is `udp` or `ipc`. After `?`, parameters are `key=value` pairs delimited by `|` (not `&`). The `endpoint` key names the remote address for senders or the group address for multicast receivers. `interface` pins the local bind address.

An address in the `224.0.0.0/4` range is multicast; `UdpChannel.parse` sets `is_multicast = true` automatically by inspecting the first octet.

---

## UdpChannel

`UdpChannel` is the parsed, validated representation of a URI. It owns a heap copy of the URI string and zero or more resolved `std.net.Address` values.

```zig
pub const UdpChannel = struct {
    uri: []const u8,
    endpoint: ?std.net.Address,
    local_address: ?std.net.Address,
    is_multicast: bool,
    mtu: ?usize,
    ttl: ?u8,
};
```

`parse` takes an allocator and a URI string, splits on `|`, and resolves each `key=value` pair:

```zig
pub fn parse(allocator: std.mem.Allocator, uri: []const u8) !UdpChannel
```

The allocator is needed for the owned URI copy and for `std.net.getAddressList` when a hostname requires DNS resolution. Callers must call `channel.deinit(allocator)` when done.

`isMulticast` detection happens inside `parseAddress`: if the resolved IPv4 address has a first octet in `[224, 239]`, `is_multicast` is set to `true`.

---

## SendChannelEndpoint

`SendChannelEndpoint` wraps a single non-blocking DGRAM socket used for outbound frames.

```zig
pub const SendChannelEndpoint = struct {
    socket: std.posix.socket_t,

    pub fn open(channel: *const UdpChannel) !SendChannelEndpoint
    pub fn send(self: *SendChannelEndpoint, dest: std.net.Address, data: []const u8) !usize
    pub fn close(self: *SendChannelEndpoint) void
};
```

`open` calls `std.posix.socket` with `SOCK.DGRAM | SOCK.NONBLOCK` and optionally `bind`s to `channel.local_address`. The address family is inferred from `channel.endpoint.any.family` so both IPv4 and IPv6 channels are handled with the same code path.

`send` delegates to `std.posix.sendto`:

```zig
return std.posix.sendto(self.socket, data, 0, &dest.any, dest.getOsSockLen());
```

No connection state is maintained. Each call to `send` names the destination explicitly, matching Aeron's model where a publication may have multiple subscribers.

---

## ReceiveChannelEndpoint

`ReceiveChannelEndpoint` handles the inbound side, including optional multicast group membership.

```zig
pub const ReceiveChannelEndpoint = struct {
    socket: std.posix.socket_t,
    bound_address: std.net.Address,

    pub fn open(channel: *const UdpChannel) !ReceiveChannelEndpoint
    pub fn bind(self: *ReceiveChannelEndpoint) !void
    pub fn joinMulticastGroup(self: *ReceiveChannelEndpoint, group: std.net.Address, interface_addr: std.net.Address) !void
    pub fn recv(self: *ReceiveChannelEndpoint, buf: []u8, src: *std.net.Address) !usize
    pub fn close(self: *ReceiveChannelEndpoint) void
};
```

For multicast channels, `open` sets `SO_REUSEPORT` before binding so that multiple processes can subscribe to the same group and port. Binding uses `0.0.0.0:port` rather than the multicast address itself, which is the portable approach across Linux and macOS.

`joinMulticastGroup` issues `IP_ADD_MEMBERSHIP` (IPv4) or `IPV6_JOIN_GROUP` (IPv6) via `setsockopt`. These constants are defined per-OS in the file because `std.posix` does not expose them on all targets:

```zig
const IP_ADD_MEMBERSHIP: u32 = switch (builtin.os.tag) {
    .macos, .ios, .watchos, .tvos => 12,
    .linux => 35,
    else => 12,
};
```

`recv` calls `std.posix.recvfrom` and fills the caller-provided `src` address:

```zig
pub fn recv(self: *ReceiveChannelEndpoint, buf: []u8, src: *std.net.Address) !usize {
    var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    return std.posix.recvfrom(self.socket, buf, 0, &src.any, &addrlen);
}
```

Both `send` and `recv` return `error.WouldBlock` (surfaced as `POSIX error EAGAIN`) when the socket has no data, because both sockets are opened with `SOCK.NONBLOCK`. The poller drives the duty cycle.

---

## Poller

`Poller` multiplexes reads across many `ReceiveChannelEndpoint` instances using `std.posix.poll`.

```zig
pub const Poller = struct {
    fds: std.ArrayList(std.posix.pollfd),
    endpoints: std.ArrayList(*ReceiveChannelEndpoint),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Poller
    pub fn add(self: *Poller, fd: std.posix.fd_t, endpoint: *ReceiveChannelEndpoint) !void
    pub fn remove(self: *Poller, fd: std.posix.fd_t) void
    pub fn poll(self: *Poller, timeout_ms: i32) ![]const std.posix.pollfd
    pub fn deinit(self: *Poller) void
};
```

`add` appends a `pollfd` entry with `events = POLL.IN` alongside a pointer to the owning endpoint. The two `ArrayList`s are kept in sync: index `i` in `fds` corresponds to index `i` in `endpoints`.

`poll` calls `std.posix.poll` on the raw slice, then returns only the entries where `revents` includes `POLL.IN`. The driver's receive duty-cycle iterates over the returned entries and calls `endpoint.recv` on each.

`remove` searches `fds` for the matching `fd` and swaps the tail element into the vacated slot, keeping both lists dense without reallocation.

---

## std.posix Socket API Summary

| Operation | Zig call |
|-----------|---------|
| Create socket | `std.posix.socket(family, type, protocol)` |
| Bind to address | `std.posix.bind(sock, &addr.any, addr.getOsSockLen())` |
| Set socket option | `std.posix.setsockopt(sock, level, optname, &value_bytes)` |
| Send datagram | `std.posix.sendto(sock, buf, flags, &dest.any, dest_len)` |
| Receive datagram | `std.posix.recvfrom(sock, buf, flags, &src.any, &src_len)` |
| Poll for readability | `std.posix.poll(fds_slice, timeout_ms)` |
| Close | `std.posix.close(sock)` |

All calls return Zig error unions; the driver never ignores a send or receive error.

---

## Next Step

With the data path complete — appender, reader, and transport — proceed to **Part 3: The Driver** to see how the `DriverConductor` orchestrates publications, subscriptions, and the flow of frames between them.
