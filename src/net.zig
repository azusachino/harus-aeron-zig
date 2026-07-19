const std = @import("std");
const builtin = @import("builtin");

pub const socket_t = std.posix.socket_t;

fn socketFlagsUnsupported() bool {
    return switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .haiku => true,
        else => false,
    };
}

fn setNonBlocking(fd: socket_t) !void {
    const rc = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
    if (std.posix.errno(rc) != .SUCCESS) return error.SocketOpenFailed;

    const flags: usize = @intCast(rc);
    const nonblock = @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
    const set_rc = std.posix.system.fcntl(fd, std.posix.F.SETFL, flags | nonblock);
    if (std.posix.errno(set_rc) != .SUCCESS) return error.SocketOpenFailed;
}

fn setCloseOnExec(fd: socket_t) !void {
    const rc = std.posix.system.fcntl(fd, std.posix.F.SETFD, @as(usize, std.posix.FD_CLOEXEC));
    if (std.posix.errno(rc) != .SUCCESS) return error.SocketOpenFailed;
}

fn asCUint(value: anytype) c_uint {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @intCast(value),
        .@"enum" => @intCast(@intFromEnum(value)),
        .@"struct" => @bitCast(value),
        else => @compileError("unsupported socket argument type"),
    };
}

pub fn openSocket(domain: anytype, sock_type: anytype, protocol: anytype) !socket_t {
    const requested_type = asCUint(sock_type);
    const requested_nonblock = (requested_type & std.posix.SOCK.NONBLOCK) != 0;
    const requested_cloexec = (requested_type & std.posix.SOCK.CLOEXEC) != 0;
    const actual_type = if (socketFlagsUnsupported())
        requested_type & ~@as(c_uint, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC)
    else
        requested_type;

    const rc = std.posix.system.socket(asCUint(domain), actual_type, asCUint(protocol));
    if (std.posix.errno(rc) != .SUCCESS) return error.SocketOpenFailed;

    const fd: socket_t = @intCast(rc);
    errdefer closeSocket(fd);

    if (requested_nonblock and socketFlagsUnsupported()) {
        try setNonBlocking(fd);
    }
    if (requested_cloexec and socketFlagsUnsupported()) {
        try setCloseOnExec(fd);
    }

    return fd;
}

pub fn closeSocket(fd: socket_t) void {
    _ = std.posix.system.close(fd);
}

pub fn bindSocket(fd: socket_t, address: *const std.posix.sockaddr, address_len: std.posix.socklen_t) !void {
    if (std.posix.errno(std.posix.system.bind(fd, address, address_len)) != .SUCCESS) return error.BindFailed;
}

/// Read back the socket's locally-bound address. After binding an ephemeral
/// port (e.g. `endpoint=host:0`), this resolves the concrete port the OS assigned.
pub fn getSockName(fd: socket_t) !Address {
    var addr: Address = undefined;
    var addrlen: std.posix.socklen_t = @sizeOf(Address);
    if (std.posix.errno(std.posix.system.getsockname(fd, &addr.any, &addrlen)) != .SUCCESS) return error.GetSockNameFailed;
    return addr;
}

pub fn setSockOpt(fd: socket_t, level: anytype, optname: anytype, value: []const u8) !void {
    std.posix.setsockopt(fd, @intCast(asCUint(level)), asCUint(optname), value) catch return error.SetSockOptFailed;
}

pub fn sendTo(fd: socket_t, data: []const u8, flags: u32, dest: *const std.posix.sockaddr, dest_len: std.posix.socklen_t) !usize {
    const rc = std.posix.system.sendto(fd, data.ptr, data.len, flags, dest, dest_len);
    if (std.posix.errno(rc) != .SUCCESS) return error.SendFailed;
    return @intCast(rc);
}

pub fn recvFrom(fd: socket_t, buf: []u8, flags: u32, src: *std.posix.sockaddr, addrlen: *std.posix.socklen_t) !usize {
    const rc = std.posix.system.recvfrom(fd, buf.ptr, buf.len, flags, src, addrlen);
    if (std.posix.errno(rc) != .SUCCESS) return error.WouldBlock;
    return @intCast(rc);
}

pub const Address = extern union {
    any: std.posix.sockaddr,
    in: std.posix.sockaddr.in,
    in6: std.posix.sockaddr.in6,

    pub fn initIp4(bytes: [4]u8, port: u16) Address {
        return .{ .in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(bytes),
        } };
    }

    pub fn initIp6(bytes: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Address {
        return .{ .in6 = .{
            .port = std.mem.nativeToBig(u16, port),
            .flowinfo = flowinfo,
            .addr = bytes,
            .scope_id = scope_id,
        } };
    }

    pub fn resolveIp(host: []const u8, port: u16) !Address {
        if (host.len == 0) return error.InvalidIPAddressFormat;
        if (std.Io.net.Ip4Address.parse(host, port)) |ip4| {
            return initIp4(ip4.bytes, ip4.port);
        } else |_| {}

        if (std.Io.net.Ip6Address.parse(host, port)) |ip6| {
            return initIp6(ip6.bytes, ip6.port, ip6.flow, ip6.interface.index);
        } else |_| {}

        // Aeron deployments commonly use DNS names for container and service endpoints.
        // The old implementation stopped after literal IP parsing, which caused the
        // conductor to silently fall back to 127.0.0.1 for valid Docker hostnames.
        var host_buf: [256:0]u8 = undefined;
        if (host.len >= host_buf.len) return error.InvalidIPAddressFormat;
        @memcpy(host_buf[0..host.len], host);
        host_buf[host.len] = 0;

        var port_buf: [6:0]u8 = undefined;
        const port_text = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch return error.InvalidIPAddressFormat;
        const hints: std.posix.addrinfo = .{
            .flags = .{},
            .family = std.posix.AF.INET,
            .socktype = std.posix.SOCK.DGRAM,
            .protocol = std.posix.IPPROTO.UDP,
            .canonname = null,
            .addr = null,
            .addrlen = 0,
            .next = null,
        };
        var result: ?*std.posix.addrinfo = null;
        const rc = std.posix.system.getaddrinfo(host_buf[0..host.len :0].ptr, port_text.ptr, &hints, &result);
        if (@intFromEnum(rc) != 0) return error.InvalidIPAddressFormat;
        defer if (result) |info| std.posix.system.freeaddrinfo(info);

        const info = result orelse return error.InvalidIPAddressFormat;
        const sockaddr = info.addr orelse return error.InvalidIPAddressFormat;
        if (info.family == std.posix.AF.INET) {
            return .{ .in = @as(*const std.posix.sockaddr.in, @ptrCast(@alignCast(sockaddr))).* };
        }
        return error.InvalidIPAddressFormat;
    }

    pub fn getPort(self: Address) u16 {
        return switch (self.any.family) {
            std.posix.AF.INET => std.mem.bigToNative(u16, self.in.port),
            std.posix.AF.INET6 => std.mem.bigToNative(u16, self.in6.port),
            else => 0,
        };
    }

    pub fn getOsSockLen(self: Address) std.posix.socklen_t {
        return switch (self.any.family) {
            std.posix.AF.INET => @sizeOf(std.posix.sockaddr.in),
            std.posix.AF.INET6 => @sizeOf(std.posix.sockaddr.in6),
            else => @sizeOf(std.posix.sockaddr),
        };
    }

    /// Format this address' host with the given port as "a.b.c.d:port" (IPv4) or
    /// "[h:h:...]:port" (IPv6). The address' own port is ignored so callers can pair a
    /// URI-supplied host with an OS-resolved ephemeral port.
    pub fn formatWithPort(self: Address, port: u16, buf: []u8) ![]const u8 {
        return switch (self.any.family) {
            std.posix.AF.INET => blk: {
                const b: [4]u8 = @bitCast(self.in.addr);
                break :blk std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{ b[0], b[1], b[2], b[3], port });
            },
            std.posix.AF.INET6 => blk: {
                const g: [8]u16 = @bitCast(self.in6.addr);
                break :blk std.fmt.bufPrint(buf, "[{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}]:{d}", .{
                    std.mem.bigToNative(u16, g[0]), std.mem.bigToNative(u16, g[1]),
                    std.mem.bigToNative(u16, g[2]), std.mem.bigToNative(u16, g[3]),
                    std.mem.bigToNative(u16, g[4]), std.mem.bigToNative(u16, g[5]),
                    std.mem.bigToNative(u16, g[6]), std.mem.bigToNative(u16, g[7]),
                    port,
                });
            },
            else => error.UnsupportedAddressFamily,
        };
    }
};

test "Address.formatWithPort pairs host with a resolved port" {
    var buf: [64]u8 = undefined;
    // IPv4 host with an OS-resolved ephemeral port; the address' own port (0) is ignored.
    const v4 = Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    try std.testing.expectEqualStrings("127.0.0.1:40123", try v4.formatWithPort(40123, &buf));

    const v6 = Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 0, 0, 0);
    try std.testing.expectEqualStrings("[0:0:0:0:0:0:0:1]:9999", try v6.formatWithPort(9999, &buf));
}
