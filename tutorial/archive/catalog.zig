// EXERCISE: Chapter 5.2 — Archive Catalog
// Reference: docs/tutorial/05-archive/02-catalog.md
//
// Your task: implement `Catalog.add` logic.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const Catalog = struct {
    pub fn add(self: *Catalog, recording_id: i64) void {
        _ = self;
        _ = recording_id;
        @panic("TODO: implement Catalog.add");
    }
};

test "Catalog add" {
    // var catalog = Catalog{};
    // catalog.add(1);
}
