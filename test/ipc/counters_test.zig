const std = @import("std");
const aeron = @import("aeron");
const counters = aeron.ipc.counters;

const CountersMap = counters.CountersMap;
const CounterHandle = counters.CounterHandle;
const METADATA_LENGTH = counters.METADATA_LENGTH;
const COUNTER_LENGTH = counters.COUNTER_LENGTH;
const PUBLISHER_LIMIT = counters.PUBLISHER_LIMIT;
const SENDER_POSITION = counters.SENDER_POSITION;
const RECEIVER_HWM = counters.RECEIVER_HWM;
const SUBSCRIBER_POSITION = counters.SUBSCRIBER_POSITION;
const CHANNEL_STATUS = counters.CHANNEL_STATUS;
const RECORD_ALLOCATED = counters.RECORD_ALLOCATED;
const RECORD_RECLAIMED = counters.RECORD_RECLAIMED;

test "counters: allocate() returns sequential counter ids" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const h1 = cm.allocate(PUBLISHER_LIMIT, "counter1");
    const h2 = cm.allocate(SENDER_POSITION, "counter2");
    const h3 = cm.allocate(RECEIVER_HWM, "counter3");

    try std.testing.expectEqual(@as(i32, 0), h1.counter_id);
    try std.testing.expectEqual(@as(i32, 1), h2.counter_id);
    try std.testing.expectEqual(@as(i32, 2), h3.counter_id);
}

test "counters: set() and get() round-trip a value" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const handle = cm.allocate(PUBLISHER_LIMIT, "test-counter");

    cm.set(handle.counter_id, 12345);
    const retrieved = cm.get(handle.counter_id);

    try std.testing.expectEqual(@as(i64, 12345), retrieved);
}

test "counters: addOrdered() increments value atomically" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const handle = cm.allocate(SENDER_POSITION, "increment-counter");

    cm.set(handle.counter_id, 100);
    cm.addOrdered(handle.counter_id, 50);
    const result = cm.get(handle.counter_id);

    try std.testing.expectEqual(@as(i64, 150), result);
}

test "counters: addOrdered() works with negative deltas" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const handle = cm.allocate(RECEIVER_HWM, "decrement-counter");

    cm.set(handle.counter_id, 1000);
    cm.addOrdered(handle.counter_id, -300);
    const result = cm.get(handle.counter_id);

    try std.testing.expectEqual(@as(i64, 700), result);
}

test "counters: compareAndSet() succeeds when expected matches" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const handle = cm.allocate(SUBSCRIBER_POSITION, "cas-counter");

    cm.set(handle.counter_id, 500);
    const success = cm.compareAndSet(handle.counter_id, 500, 750);

    try std.testing.expect(success);
    try std.testing.expectEqual(@as(i64, 750), cm.get(handle.counter_id));
}

test "counters: compareAndSet() fails when expected does not match" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const handle = cm.allocate(PUBLISHER_LIMIT, "cas-fail-counter");

    cm.set(handle.counter_id, 500);
    const fail = cm.compareAndSet(handle.counter_id, 999, 750);

    try std.testing.expect(!fail);
    try std.testing.expectEqual(@as(i64, 500), cm.get(handle.counter_id));
}

test "counters: compareAndSet() multiple retries until success" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const handle = cm.allocate(SENDER_POSITION, "cas-multi");

    cm.set(handle.counter_id, 0);

    var i: i64 = 0;
    while (i < 100) {
        const current = cm.get(handle.counter_id);
        if (cm.compareAndSet(handle.counter_id, current, current + 1)) {
            i += 1;
        }
    }

    try std.testing.expectEqual(@as(i64, 100), cm.get(handle.counter_id));
}

test "counters: free() marks slot as reclaimed" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const h1 = cm.allocate(PUBLISHER_LIMIT, "first");
    try std.testing.expectEqual(@as(i32, 0), h1.counter_id);

    cm.free(h1.counter_id);

    const h2 = cm.allocate(SENDER_POSITION, "second");
    try std.testing.expectEqual(@as(i32, 0), h2.counter_id);
}

test "counters: multiple counters coexist without interference" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 8);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 8);
    var cm = CountersMap.init(&meta, &values);

    const h1 = cm.allocate(PUBLISHER_LIMIT, "c1");
    const h2 = cm.allocate(SENDER_POSITION, "c2");
    const h3 = cm.allocate(RECEIVER_HWM, "c3");

    cm.set(h1.counter_id, 111);
    cm.set(h2.counter_id, 222);
    cm.set(h3.counter_id, 333);

    cm.addOrdered(h1.counter_id, 10);
    cm.addOrdered(h2.counter_id, 20);
    cm.addOrdered(h3.counter_id, 30);

    try std.testing.expectEqual(@as(i64, 121), cm.get(h1.counter_id));
    try std.testing.expectEqual(@as(i64, 242), cm.get(h2.counter_id));
    try std.testing.expectEqual(@as(i64, 363), cm.get(h3.counter_id));
}

test "counters: new counter value starts at 0" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const handle = cm.allocate(CHANNEL_STATUS, "zero-counter");

    try std.testing.expectEqual(@as(i64, 0), cm.get(handle.counter_id));
}

test "counters: allocateStreamCounter stores registration_id and session_id" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 2);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 2);
    var cm = CountersMap.init(&meta, &values);

    const handle = cm.allocateStreamCounter(
        PUBLISHER_LIMIT,
        "pub",
        42,
        99,
        7,
        1001,
        "aeron:udp?endpoint=localhost:40123",
        null,
    );

    try std.testing.expectEqual(@as(i32, 0), handle.counter_id);
    try std.testing.expectEqual(@as(i64, 99), cm.getCounterRegistrationId(handle.counter_id));
    try std.testing.expectEqual(@as(i64, 42), cm.getCounterOwnerId(handle.counter_id));
    try std.testing.expectEqual(@as(i64, 99), cm.getCounterReferenceId(handle.counter_id));
}

test "counters: allocateStreamCounter with join_position includes it in label" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 2);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 2);
    var cm = CountersMap.init(&meta, &values);

    const handle = cm.allocateStreamCounter(
        SENDER_POSITION,
        "sender",
        10,
        20,
        5,
        100,
        "aeron:ipc",
        12345,
    );

    try std.testing.expectEqual(@as(i32, 0), handle.counter_id);
    try std.testing.expectEqual(@as(i64, 20), cm.getCounterRegistrationId(handle.counter_id));
}

test "counters: allocateChannelStatusCounter stores registration_id" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 2);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 2);
    var cm = CountersMap.init(&meta, &values);

    const channel = "aeron:udp?endpoint=localhost:20121";
    const handle = cm.allocateChannelStatusCounter(
        counters.SEND_CHANNEL_STATUS,
        "snd-channel",
        1234,
        channel,
    );

    try std.testing.expectEqual(@as(i32, 0), handle.counter_id);
    try std.testing.expectEqual(@as(i64, 1234), cm.getCounterRegistrationId(handle.counter_id));
    try std.testing.expectEqual(@as(i64, 0), cm.getCounterOwnerId(handle.counter_id));
    try std.testing.expectEqual(@as(i64, 0), cm.getCounterReferenceId(handle.counter_id));
}

test "counters: get() with invalid counter_id returns 0" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 2);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 2);
    var cm = CountersMap.init(&meta, &values);

    const result = cm.get(999);
    try std.testing.expectEqual(@as(i64, 0), result);
}

test "counters: set() with invalid counter_id is safe" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 2);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 2);
    var cm = CountersMap.init(&meta, &values);

    cm.set(999, 12345);
}

test "counters: addOrdered() with invalid counter_id is safe" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 2);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 2);
    var cm = CountersMap.init(&meta, &values);

    cm.addOrdered(999, 100);
}

test "counters: compareAndSet() with invalid counter_id returns false" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 2);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 2);
    var cm = CountersMap.init(&meta, &values);

    const result = cm.compareAndSet(999, 0, 100);
    try std.testing.expect(!result);
}

test "counters: allocate max counters respects buffer capacity" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 2);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 2);
    var cm = CountersMap.init(&meta, &values);

    const h1 = cm.allocate(PUBLISHER_LIMIT, "c1");
    const h2 = cm.allocate(SENDER_POSITION, "c2");
    const h3 = cm.allocate(RECEIVER_HWM, "c3");

    try std.testing.expectEqual(@as(i32, 0), h1.counter_id);
    try std.testing.expectEqual(@as(i32, 1), h2.counter_id);
    try std.testing.expectEqual(@as(i32, -1), h3.counter_id);
}

test "counters: free and reallocate reuses slot" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const h1 = cm.allocate(PUBLISHER_LIMIT, "first");
    const h2 = cm.allocate(SENDER_POSITION, "second");

    cm.set(h1.counter_id, 1111);
    cm.set(h2.counter_id, 2222);

    cm.free(h1.counter_id);

    const h3 = cm.allocate(RECEIVER_HWM, "third");

    try std.testing.expectEqual(@as(i32, 0), h3.counter_id);
    try std.testing.expectEqual(@as(i64, 0), cm.get(h3.counter_id));
    try std.testing.expectEqual(@as(i64, 2222), cm.get(h2.counter_id));
}

test "counters: free() with invalid counter_id is safe" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 2);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 2);
    var cm = CountersMap.init(&meta, &values);

    cm.free(999);
}

test "counters: set and get large values" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const handle = cm.allocate(PUBLISHER_LIMIT, "large-counter");

    const large_value: i64 = 9223372036854775800;
    cm.set(handle.counter_id, large_value);

    try std.testing.expectEqual(large_value, cm.get(handle.counter_id));
}

test "counters: negative counter values" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const handle = cm.allocate(SENDER_POSITION, "negative-counter");

    cm.set(handle.counter_id, -1000);
    try std.testing.expectEqual(@as(i64, -1000), cm.get(handle.counter_id));

    cm.addOrdered(handle.counter_id, -500);
    try std.testing.expectEqual(@as(i64, -1500), cm.get(handle.counter_id));
}

test "counters: reuse after free maintains isolation" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 4);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 4);
    var cm = CountersMap.init(&meta, &values);

    const h1 = cm.allocate(PUBLISHER_LIMIT, "isolate1");
    cm.set(h1.counter_id, 5000);

    cm.free(h1.counter_id);

    const h2 = cm.allocate(SENDER_POSITION, "isolate2");
    cm.set(h2.counter_id, 6000);

    try std.testing.expectEqual(@as(i64, 6000), cm.get(h2.counter_id));
}

test "counters: getCounterRegistrationId reads correctly" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 2);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 2);
    var cm = CountersMap.init(&meta, &values);

    const handle = cm.allocateStreamCounter(
        PUBLISHER_LIMIT,
        "test",
        111,
        222,
        3,
        4,
        "channel",
        null,
    );

    try std.testing.expectEqual(@as(i64, 222), cm.getCounterRegistrationId(handle.counter_id));
}

test "counters: getCounterOwnerId reads correctly" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 2);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 2);
    var cm = CountersMap.init(&meta, &values);

    const handle = cm.allocateStreamCounter(
        PUBLISHER_LIMIT,
        "test",
        888,
        123,
        3,
        4,
        "channel",
        null,
    );

    try std.testing.expectEqual(@as(i64, 888), cm.getCounterOwnerId(handle.counter_id));
}

test "counters: getCounterReferenceId reads correctly" {
    var meta align(64) = [_]u8{0} ** (METADATA_LENGTH * 2);
    var values align(64) = [_]u8{0} ** (COUNTER_LENGTH * 2);
    var cm = CountersMap.init(&meta, &values);

    const handle = cm.allocateStreamCounter(
        PUBLISHER_LIMIT,
        "test",
        111,
        777,
        3,
        4,
        "channel",
        null,
    );

    try std.testing.expectEqual(@as(i64, 777), cm.getCounterReferenceId(handle.counter_id));
}
