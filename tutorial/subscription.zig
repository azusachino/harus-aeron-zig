// EXERCISE: Chapter 4.2 — Subscription
// Reference: docs/tutorial/04-client/02-subscriptions.md
//
// Your task: implement `poll` logic.
// Run `make tutorial-check` to verify your solution.

const std = @import("std");

pub const Subscription = struct {
    pub fn poll(self: *Subscription, handler: anytype, ctx: *anyopaque, limit: i32) i32 {
        _ = self;
        _ = handler;
        _ = ctx;
        _ = limit;
        @panic("TODO: implement Subscription.poll");
    }
};

test "Subscription poll" {
    // var sub = Subscription{};
    // _ = sub.poll(null, undefined, 10);
}
