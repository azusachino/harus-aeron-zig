const std = @import("std");

/// IdleStrategy is used to back off when no work is available.
/// It can be used by driver agents (Conductor, Sender, Receiver) or clients.
pub const IdleStrategy = union(enum) {
    busy_spin: BusySpinIdleStrategy,
    yielding: YieldingIdleStrategy,
    sleeping: SleepingIdleStrategy,
    backoff: BackoffIdleStrategy,

    pub fn idle(self: *IdleStrategy, work_count: i32) void {
        switch (self.*) {
            inline else => |*strategy| strategy.idle(work_count),
        }
    }

    pub fn reset(self: *IdleStrategy) void {
        switch (self.*) {
            inline else => |*strategy| strategy.reset(),
        }
    }

    /// Helper to create a busy spin strategy.
    pub fn initBusySpin() IdleStrategy {
        return .{ .busy_spin = BusySpinIdleStrategy{} };
    }

    /// Helper to create a yielding strategy.
    pub fn initYielding() IdleStrategy {
        return .{ .yielding = YieldingIdleStrategy{} };
    }

    /// Helper to create a sleeping strategy.
    pub fn initSleeping(ns: u64) IdleStrategy {
        return .{ .sleeping = SleepingIdleStrategy{ .sleep_ns = ns } };
    }

    /// Helper to create a backoff strategy with default parameters.
    pub fn initBackoff(max_spins: i64, max_yields: i64, min_park_ns: u64, max_park_ns: u64) IdleStrategy {
        return .{
            .backoff = BackoffIdleStrategy.init(max_spins, max_yields, min_park_ns, max_park_ns),
        };
    }

    pub fn initDefaultBackoff() IdleStrategy {
        return initBackoff(10, 20, 1_000, 1_000_000); // 1us to 1ms
    }
};

pub const BusySpinIdleStrategy = struct {
    pub fn idle(_: *BusySpinIdleStrategy, work_count: i32) void {
        if (work_count > 0) return;
        std.atomic.spinLoopHint();
    }

    pub fn reset(_: *BusySpinIdleStrategy) void {}
};

pub const YieldingIdleStrategy = struct {
    pub fn idle(_: *YieldingIdleStrategy, work_count: i32) void {
        if (work_count > 0) return;
        std.Thread.yield() catch {};
    }

    pub fn reset(_: *YieldingIdleStrategy) void {}
};

pub const SleepingIdleStrategy = struct {
    sleep_ns: u64,

    pub fn idle(self: *SleepingIdleStrategy, work_count: i32) void {
        if (work_count > 0) return;
        std.Thread.sleep(self.sleep_ns);
    }

    pub fn reset(_: *SleepingIdleStrategy) void {}
};

pub const BackoffIdleStrategy = struct {
    max_spins: i64,
    max_yields: i64,
    min_park_ns: u64,
    max_park_ns: u64,

    spins: i64 = 0,
    yields: i64 = 0,
    park_ns: u64 = 0,
    state: State = .not_idle,

    const State = enum {
        not_idle,
        spinning,
        yielding,
        parking,
    };

    pub fn init(max_spins: i64, max_yields: i64, min_park_ns: u64, max_park_ns: u64) BackoffIdleStrategy {
        return .{
            .max_spins = max_spins,
            .max_yields = max_yields,
            .min_park_ns = min_park_ns,
            .max_park_ns = max_park_ns,
            .park_ns = min_park_ns,
        };
    }

    pub fn idle(self: *BackoffIdleStrategy, work_count: i32) void {
        if (work_count > 0) {
            self.reset();
            return;
        }

        switch (self.state) {
            .not_idle => {
                self.state = .spinning;
                self.spins = 1;
                std.atomic.spinLoopHint();
            },
            .spinning => {
                std.atomic.spinLoopHint();
                self.spins += 1;
                if (self.spins > self.max_spins) {
                    self.state = .yielding;
                    self.yields = 0;
                }
            },
            .yielding => {
                self.yields += 1;
                if (self.yields > self.max_yields) {
                    self.state = .parking;
                    self.park_ns = self.min_park_ns;
                    std.Thread.sleep(self.park_ns);
                } else {
                    std.Thread.yield() catch {};
                }
            },
            .parking => {
                std.Thread.sleep(self.park_ns);
                self.park_ns = @min(self.park_ns * 2, self.max_park_ns);
            },
        }
    }

    pub fn reset(self: *BackoffIdleStrategy) void {
        self.spins = 0;
        self.yields = 0;
        self.park_ns = self.min_park_ns;
        self.state = .not_idle;
    }
};
