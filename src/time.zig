const std = @import("std");

pub fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) {
        @panic("clock_gettime failed");
    }

    return (@as(i128, ts.sec) * std.time.ns_per_s) + @as(i128, ts.nsec);
}

pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_ms));
}
