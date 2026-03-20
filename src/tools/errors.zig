// Error log reader.
// Reads and displays error log entries from aeron_dir/error.log.
const std = @import("std");

pub fn run(aeron_dir: []const u8) void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build path to error.log
    const error_log_path = std.fmt.allocPrint(allocator, "{s}/error.log", .{aeron_dir}) catch {
        stdout.interface.print("Error: could not allocate path\n", .{}) catch return;
        return;
    };
    defer allocator.free(error_log_path);

    // Try to open and read error.log
    const file = std.fs.cwd().openFile(error_log_path, .{}) catch {
        stdout.interface.print("No error log found at {s}\n", .{error_log_path}) catch return;
        return;
    };
    defer file.close();

    stdout.interface.print("Error Log — {s}\n", .{error_log_path}) catch return;
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
