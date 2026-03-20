const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    aeron_dir: []const u8,
    term_buffer_length: i32,
    mtu_length: i32,
    client_timeout_ns: i64,
    log_level: []const u8,
    log_format: []const u8,
    health_port: u16,

    pub fn fromEnv() Config {
        return .{
            .aeron_dir = std.posix.getenv("AERON_DIR") orelse defaultAeronDir(),
            .term_buffer_length = parseEnvInt(i32, "AERON_TERM_LENGTH", 16 * 1024 * 1024),
            .mtu_length = parseEnvInt(i32, "AERON_MTU", 1408),
            .client_timeout_ns = parseEnvInt(i64, "AERON_CLIENT_TIMEOUT_NS", 5_000_000_000),
            .log_level = std.posix.getenv("AERON_LOG_LEVEL") orelse "info",
            .log_format = std.posix.getenv("AERON_LOG_FORMAT") orelse "json",
            .health_port = parseEnvInt(u16, "AERON_HEALTH_PORT", 8080),
        };
    }

    fn defaultAeronDir() []const u8 {
        return if (builtin.os.tag == .linux) "/dev/shm/aeron" else "/tmp/aeron";
    }

    fn parseEnvInt(comptime T: type, name: []const u8, default: T) T {
        const val = std.posix.getenv(name) orelse return default;
        return std.fmt.parseInt(T, val, 10) catch default;
    }

    pub fn validate(self: Config) ?[]const u8 {
        if (self.term_buffer_length < 64 * 1024) return "AERON_TERM_LENGTH must be >= 65536";
        if (self.mtu_length < 256 or self.mtu_length > 65536) return "AERON_MTU must be 256-65536";
        if (self.health_port == 0) return "AERON_HEALTH_PORT must be > 0";
        return null;
    }
};

const testing = std.testing;

test "Config: fromEnv uses defaults" {
    const cfg = Config.fromEnv();
    try testing.expect(cfg.term_buffer_length == 16 * 1024 * 1024);
    try testing.expect(cfg.mtu_length == 1408);
    try testing.expect(cfg.health_port == 8080);
}

test "Config: validate succeeds with defaults" {
    try testing.expect(Config.fromEnv().validate() == null);
}

test "Config: validate rejects small term_buffer_length" {
    const cfg = Config{ .aeron_dir = "/tmp/aeron", .term_buffer_length = 32 * 1024, .mtu_length = 1408, .client_timeout_ns = 5_000_000_000, .log_level = "info", .log_format = "json", .health_port = 8080 };
    try testing.expect(cfg.validate() != null);
}

test "Config: validate rejects invalid MTU" {
    const cfg = Config{ .aeron_dir = "/tmp/aeron", .term_buffer_length = 16 * 1024 * 1024, .mtu_length = 100, .client_timeout_ns = 5_000_000_000, .log_level = "info", .log_format = "json", .health_port = 8080 };
    try testing.expect(cfg.validate() != null);
}

test "Config: validate rejects zero health_port" {
    const cfg = Config{ .aeron_dir = "/tmp/aeron", .term_buffer_length = 16 * 1024 * 1024, .mtu_length = 1408, .client_timeout_ns = 5_000_000_000, .log_level = "info", .log_format = "json", .health_port = 0 };
    try testing.expect(cfg.validate() != null);
}

test "Config: defaultAeronDir platform-specific" {
    const dir = Config.fromEnv().aeron_dir;
    if (builtin.os.tag == .linux) {
        try testing.expectEqualStrings("/dev/shm/aeron", dir);
    } else {
        try testing.expectEqualStrings("/tmp/aeron", dir);
    }
}
