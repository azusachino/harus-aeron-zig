// Error log reader.
// Reads and displays error log entries from aeron_dir/error.log.
const std = @import("std");
const cnc_mod = @import("../cnc.zig");

pub fn run(aeron_dir: []const u8) void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const desc = cnc_mod.CncDescriptor.init(aeron_dir);

    // Get error log path from CnC descriptor
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const error_log_path = desc.errorLogPath(&path_buf);

    // Try to open and read error.log
    const file = std.fs.openFileAbsolute(error_log_path, .{}) catch |err| {
        stdout.interface.print("Error Log — {s}\n", .{aeron_dir}) catch return;
        stdout.interface.print("==============================\n\n", .{}) catch return;
        stdout.interface.print("Could not open error log at {s}: {any}\n", .{ error_log_path, err }) catch return;
        return;
    };
    defer file.close();

    stdout.interface.print("Error Log — {s}\n", .{aeron_dir}) catch return;
    stdout.interface.print("==============================\n\n", .{}) catch return;

    const contents = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        stdout.interface.print("Could not read error log (too large or read error)\n", .{}) catch return;
        return;
    };
    defer allocator.free(contents);

    if (contents.len == 0) {
        stdout.interface.print("No errors recorded.\n", .{}) catch return;
    } else {
        stdout.interface.print("{s}\n", .{contents}) catch return;
    }
}

test "errors: reports when error log missing" {
    // Verify that run() gracefully handles missing error log
    run("/tmp/nonexistent-aeron");
}

// ============================================================================
// UNIT TESTS
// ============================================================================

test "errors tool: errorLogPath via CncDescriptor" {
    const desc = cnc_mod.CncDescriptor.init("/tmp/aeron");
    var buf: [256]u8 = undefined;
    const path = desc.errorLogPath(&buf);
    try std.testing.expectEqualStrings("/tmp/aeron/error.log", path);
}

test "errors tool: reads error.log fixture" {
    const allocator = std.testing.allocator;

    const dir_path = "/tmp/harus-aeron-errors-tool-test";
    defer std.fs.deleteTreeAbsolute(dir_path) catch {};
    try std.fs.makeDirAbsolute(dir_path);

    const log_path = try std.fmt.allocPrint(allocator, "{s}/error.log", .{dir_path});
    defer allocator.free(log_path);

    {
        const f = try std.fs.cwd().createFile(log_path, .{});
        defer f.close();
        try f.writeAll("ERROR: test error message\n");
    }

    const f2 = try std.fs.cwd().openFile(log_path, .{});
    defer f2.close();
    const contents = try f2.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(contents);

    try std.testing.expect(contents.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, contents, "test error message") != null);
}

test "errors tool: empty error.log detected" {
    const allocator = std.testing.allocator;

    const dir_path = "/tmp/harus-aeron-errors-tool-empty";
    defer std.fs.deleteTreeAbsolute(dir_path) catch {};
    try std.fs.makeDirAbsolute(dir_path);

    const log_path = try std.fmt.allocPrint(allocator, "{s}/error.log", .{dir_path});
    defer allocator.free(log_path);

    {
        const f = try std.fs.cwd().createFile(log_path, .{});
        defer f.close();
        // write nothing
    }

    const f2 = try std.fs.cwd().openFile(log_path, .{});
    defer f2.close();
    const contents = try f2.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(contents);

    try std.testing.expectEqual(@as(usize, 0), contents.len);
}
