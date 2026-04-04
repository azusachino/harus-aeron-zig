// EXERCISE: Chapter 4.1 — Publication
// Reference: docs/tutorial/04-client/01-publications.md
//
// Your task: implement `offer` logic.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const Publication = struct {
    pub fn offer(self: *Publication, buffer: []const u8) i64 {
        _ = self;
        _ = buffer;
        @panic("TODO: implement Publication.offer");
    }
};

test "Publication offer" {
    // var pub_instance = Publication{};
    // _ = pub_instance.offer("hello");
}
