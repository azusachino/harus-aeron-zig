// EXERCISE: Chapter 3.3 — Command and Control (CnC) Reader
// Reference: docs/tutorial/03-driver/C-6-conductor.md
//
// Your task: implement `CncDescriptor.cncFilePath` and other path generators.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const CncDescriptor = struct {
    aeron_dir: []const u8,

    pub fn init(aeron_dir: []const u8) CncDescriptor {
        return .{ .aeron_dir = aeron_dir };
    }

    pub fn cncFilePath(self: CncDescriptor, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/cnc.dat", .{self.aeron_dir}) catch buf[0..0];
    }

    pub fn errorLogPath(self: CncDescriptor, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/error.log", .{self.aeron_dir}) catch buf[0..0];
    }

    pub fn lossReportPath(self: CncDescriptor, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/loss-report.dat", .{self.aeron_dir}) catch buf[0..0];
    }
};

test "CncDescriptor learner stub" {
    // Tests for learner stub
}
