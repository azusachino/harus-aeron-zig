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
        _ = self;
        _ = buf;
        @panic("TODO: implement cncFilePath to return aeron_dir/cnc.dat");
    }

    pub fn errorLogPath(self: CncDescriptor, buf: []u8) []const u8 {
        _ = self;
        _ = buf;
        @panic("TODO: implement errorLogPath to return aeron_dir/error.log");
    }

    pub fn lossReportPath(self: CncDescriptor, buf: []u8) []const u8 {
        _ = self;
        _ = buf;
        @panic("TODO: implement lossReportPath to return aeron_dir/loss-report.dat");
    }
};

test "CncDescriptor learner stub" {
    // Tests for learner stub
}
