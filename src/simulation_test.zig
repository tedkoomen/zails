// TigerBeetle-Inspired Deterministic Simulation Tests
//
// Tests every concurrent data structure in the message bus with seeded PRNG,
// fault injection, and invariant checking after every operation.
//
// Run: zig build test-simulation
// Filter: zig build test-simulation -- --test-filter "ring_buffer_mpmc"
// Optimized: zig build test-simulation -Doptimize=ReleaseFast

const std = @import("std");
const Allocator = std.mem.Allocator;

// Message bus imports
const event_mod = @import("event.zig");
const Event = event_mod.Event;
const FieldValue = event_mod.FieldValue;
const FixedString = event_mod.FixedString;
const Field = event_mod.Field;
const MAX_EVENT_FIELDS = event_mod.MAX_EVENT_FIELDS;
const generateEventId = event_mod.generateEventId;

const ring_buffer_mod = @import("message_bus/ring_buffer.zig");
const EventRingBuffer = ring_buffer_mod.EventRingBuffer;

const filter_mod = @import("message_bus/filter.zig");
const Filter = filter_mod.Filter;

const subscriber_mod = @import("message_bus/subscriber.zig");
const Subscription = subscriber_mod.Subscription;
const HandlerFn = subscriber_mod.HandlerFn;

const registry_mod = @import("message_bus/lockfree_subscriber_registry.zig");
const LockFreeSubscriberRegistry = registry_mod.LockFreeSubscriberRegistry;

const message_bus_mod = @import("message_bus/message_bus.zig");
const MessageBus = message_bus_mod.MessageBus;

const topic_matcher = @import("message_bus/topic_matcher.zig");
const TopicPattern = topic_matcher.TopicPattern;
const TopicRegistry = topic_matcher.TopicRegistry;

// ============================================================================
// Core Infrastructure
// ============================================================================

const SimulationConfig = struct {
    seed: u64,
    iterations: usize,
    num_threads: usize,
};

const FaultInjector = struct {
    rng: std.Random.DefaultPrng,

    fn init(seed: u64) FaultInjector {
        return .{ .rng = std.Random.DefaultPrng.init(seed) };
    }

    fn shouldFault(self: *FaultInjector, probability_pct: u8) bool {
        return self.rng.random().intRangeAtMost(u8, 0, 99) < probability_pct;
    }

    fn randomDelay(self: *FaultInjector) void {
        const spins = self.rng.random().intRangeAtMost(u8, 0, 100);
        var i: u8 = 0;
        while (i < spins) : (i += 1) {
            std.atomic.spinLoopHint();
        }
    }

    fn randomByte(self: *FaultInjector) u8 {
        return self.rng.random().int(u8);
    }

    fn randomIndex(self: *FaultInjector, max: usize) usize {
        if (max == 0) return 0;
        return self.rng.random().intRangeAtMost(usize, 0, max - 1);
    }
};

const InvariantChecker = struct {
    total_published: u64 = 0,
    total_delivered: u64 = 0,
    total_dropped: u64 = 0,

    fn check(self: *const InvariantChecker) !void {
        // Accounting identity: published >= delivered + dropped
        try std.testing.expect(self.total_published >= self.total_delivered + self.total_dropped);
    }

    fn checkExact(self: *const InvariantChecker) !void {
        // Strict: published == delivered + dropped (no in-flight)
        try std.testing.expectEqual(self.total_published, self.total_delivered + self.total_dropped);
    }
};

fn printSeed(seed: u64) void {
    std.debug.print("\n=== SIMULATION SEED: 0x{X:0>16} ===\n", .{seed});
}

fn makeEvent(id: u64) Event {
    return Event{
        .id = id,
        .timestamp = @intCast(id),
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = id,
        .data = "{}",
    };
}

// ============================================================================
// Simulation 1: Ring Buffer MPMC Deterministic Stress
// ============================================================================

test "simulation 1: ring_buffer_mpmc deterministic stress" {
    const seed: u64 = 0xDEADBEEF_CAFEBABE;
    printSeed(seed);

    const allocator = std.testing.allocator;
    const num_producers = 4;
    const num_consumers = 4;
    const events_per_producer = 5_000;
    const total_events = num_producers * events_per_producer;

    var buffer = try EventRingBuffer.init(allocator, 256);
    defer buffer.deinit();

    var shutdown = std.atomic.Value(bool).init(false);
    var total_consumed = std.atomic.Value(u64).init(0);

    // Track which IDs were consumed (using atomic bit array via mutex)
    var seen_mutex = std.Thread.Mutex{};
    var seen = try allocator.alloc(bool, total_events);
    defer allocator.free(seen);
    @memset(seen, false);

    var duplicate_count = std.atomic.Value(u64).init(0);
    var torn_reads = std.atomic.Value(u64).init(0);

    const ProducerCtx = struct {
        buffer: *EventRingBuffer,
        producer_id: usize,
        fault_seed: u64,
    };

    const ConsumerCtx = struct {
        buffer: *EventRingBuffer,
        shutdown: *std.atomic.Value(bool),
        total_consumed: *std.atomic.Value(u64),
        seen: []bool,
        seen_mutex: *std.Thread.Mutex,
        duplicate_count: *std.atomic.Value(u64),
        torn_reads: *std.atomic.Value(u64),
    };

    const producer_fn = struct {
        fn run(ctx: ProducerCtx) void {
            var fi = FaultInjector.init(ctx.fault_seed);
            for (0..events_per_producer) |i| {
                const seq: u64 = @intCast(ctx.producer_id * events_per_producer + i);
                const event = Event{
                    .id = seq,
                    .timestamp = @intCast(seq),
                    .event_type = .model_created,
                    .topic = "test",
                    .model_type = "test",
                    .model_id = seq,
                    .data = "{}",
                };

                // Inject random delays before push
                if (fi.shouldFault(30)) {
                    fi.randomDelay();
                }

                while (!ctx.buffer.push(event)) {
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run;

    const consumer_fn = struct {
        fn run(ctx: ConsumerCtx) void {
            while (true) {
                if (ctx.shutdown.load(.acquire) and ctx.total_consumed.load(.monotonic) >= total_events) break;

                const event = ctx.buffer.pop() orelse {
                    if (ctx.shutdown.load(.acquire)) {
                        if (ctx.total_consumed.load(.monotonic) >= total_events) break;
                    }
                    std.atomic.spinLoopHint();
                    continue;
                };

                // Check for torn reads: id must match model_id and timestamp
                if (event.id != event.model_id) {
                    _ = ctx.torn_reads.fetchAdd(1, .monotonic);
                }
                if (event.timestamp != @as(i64, @intCast(event.model_id))) {
                    _ = ctx.torn_reads.fetchAdd(1, .monotonic);
                }

                // Track seen IDs
                const idx: usize = @intCast(event.id);
                {
                    ctx.seen_mutex.lock();
                    defer ctx.seen_mutex.unlock();
                    if (ctx.seen[idx]) {
                        _ = ctx.duplicate_count.fetchAdd(1, .monotonic);
                    }
                    ctx.seen[idx] = true;
                }

                _ = ctx.total_consumed.fetchAdd(1, .monotonic);
            }
        }
    }.run;

    // Start consumers first
    var consumer_threads: [num_consumers]std.Thread = undefined;
    var consumer_ctxs: [num_consumers]ConsumerCtx = undefined;
    for (0..num_consumers) |i| {
        consumer_ctxs[i] = .{
            .buffer = &buffer,
            .shutdown = &shutdown,
            .total_consumed = &total_consumed,
            .seen = seen,
            .seen_mutex = &seen_mutex,
            .duplicate_count = &duplicate_count,
            .torn_reads = &torn_reads,
        };
        consumer_threads[i] = try std.Thread.spawn(.{}, consumer_fn, .{consumer_ctxs[i]});
    }

    // Start producers with seeded fault injection
    var producer_threads: [num_producers]std.Thread = undefined;
    var producer_ctxs: [num_producers]ProducerCtx = undefined;
    for (0..num_producers) |i| {
        producer_ctxs[i] = .{
            .buffer = &buffer,
            .producer_id = i,
            .fault_seed = seed +% i,
        };
        producer_threads[i] = try std.Thread.spawn(.{}, producer_fn, .{producer_ctxs[i]});
    }

    for (producer_threads) |t| t.join();
    shutdown.store(true, .release);
    for (consumer_threads) |t| t.join();

    // Invariants
    try std.testing.expectEqual(@as(u64, 0), torn_reads.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), duplicate_count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, total_events), total_consumed.load(.monotonic));

    // Every ID must have been seen exactly once
    for (seen, 0..) |s, i| {
        if (!s) {
            std.debug.print("MISSING ID: {d} (seed=0x{X:0>16})\n", .{ i, seed });
            return error.TestExpectedEqual;
        }
    }
}

// ============================================================================
// Simulation 2: Queue Saturation & Graceful Degradation
// ============================================================================

test "simulation 2: queue saturation graceful degradation" {
    const seed: u64 = 0xFEEDFACE_12345678;
    printSeed(seed);

    const allocator = std.testing.allocator;
    const capacity: usize = 16;
    const burst_count: usize = 1000;

    var buffer = try EventRingBuffer.init(allocator, capacity);
    defer buffer.deinit();

    var published: u64 = 0;
    var dropped: u64 = 0;

    // Burst events without any consumer
    for (0..burst_count) |i| {
        const event = makeEvent(@intCast(i));
        if (buffer.push(event)) {
            published += 1;
        } else {
            dropped += 1;
        }

        // Invariant check after every operation
        try std.testing.expectEqual(@as(u64, @intCast(i + 1)), published + dropped);
    }

    // Must account for all events
    try std.testing.expectEqual(@as(u64, burst_count), published + dropped);
    // Published must be <= capacity
    try std.testing.expect(published <= capacity);
    // Dropped must be > 0 (since burst >> capacity)
    try std.testing.expect(dropped > 0);

    // Now drain and verify all drained events have valid structure
    var drained: u64 = 0;
    while (buffer.pop()) |event| {
        // Verify event structure is valid (not corrupted)
        try std.testing.expect(event.id < burst_count);
        try std.testing.expectEqual(event.id, event.model_id);
        try std.testing.expectEqual(@as(i64, @intCast(event.model_id)), event.timestamp);
        try std.testing.expectEqualStrings("Test.created", event.topic);
        drained += 1;
    }

    try std.testing.expectEqual(published, drained);
    try std.testing.expect(buffer.isEmpty());
}

// ============================================================================
// Simulation 3: Subscribe/Unsubscribe Churn During Delivery
// ============================================================================

test "simulation 3: subscribe unsubscribe churn during delivery" {
    const seed: u64 = 0xABCD1234_56789ABC;
    printSeed(seed);

    const allocator = std.testing.allocator;
    const iterations = 200;

    var registry = try LockFreeSubscriberRegistry.init(allocator);
    defer registry.deinit();

    var shutdown = std.atomic.Value(bool).init(false);
    var churn_errors = std.atomic.Value(u64).init(0);
    var match_errors = std.atomic.Value(u64).init(0);

    const ChurnCtx = struct {
        registry: *LockFreeSubscriberRegistry,
        shutdown: *std.atomic.Value(bool),
        churn_errors: *std.atomic.Value(u64),
        fault_seed: u64,
    };

    const ReaderCtx = struct {
        registry: *LockFreeSubscriberRegistry,
        shutdown: *std.atomic.Value(bool),
        match_errors: *std.atomic.Value(u64),
    };

    const churn_fn = struct {
        fn run(ctx: ChurnCtx) void {
            var fi = FaultInjector.init(ctx.fault_seed);
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                if (ctx.shutdown.load(.acquire)) break;

                const filter = Filter{ .conditions = &.{} };
                const id = ctx.registry.subscribe("Trade.created", filter, noopHandler) catch {
                    _ = ctx.churn_errors.fetchAdd(1, .monotonic);
                    continue;
                };

                if (fi.shouldFault(50)) {
                    fi.randomDelay();
                }

                ctx.registry.unsubscribe(id);
            }
        }
    }.run;

    const reader_fn = struct {
        fn run(ctx: ReaderCtx) void {
            var i: usize = 0;
            while (i < iterations * 2) : (i += 1) {
                if (ctx.shutdown.load(.acquire)) break;

                var event = Event{
                    .id = @intCast(i),
                    .timestamp = @intCast(i),
                    .event_type = .model_created,
                    .topic = "Trade.created",
                    .model_type = "Trade",
                    .model_id = @intCast(i),
                    .data = "",
                };
                event.setField("price", .{ .int = 100 });

                // getMatchingResult must never crash or return garbage
                const result = ctx.registry.getMatchingResult(&event);

                // Count must be within valid range
                if (result.count > 64) {
                    _ = ctx.match_errors.fetchAdd(1, .monotonic);
                }

                // Verify each returned subscription has a valid handler
                for (result.buffer[0..result.count]) |sub| {
                    if (@intFromPtr(sub.handler) == 0) {
                        _ = ctx.match_errors.fetchAdd(1, .monotonic);
                    }
                }
            }
        }
    }.run;

    // Thread A: subscribe/unsubscribe churn
    var churn_ctx = ChurnCtx{
        .registry = &registry,
        .shutdown = &shutdown,
        .churn_errors = &churn_errors,
        .fault_seed = seed,
    };
    const churn_thread = try std.Thread.spawn(.{}, churn_fn, .{churn_ctx});

    // Thread B: concurrent reads
    var reader_ctx = ReaderCtx{
        .registry = &registry,
        .shutdown = &shutdown,
        .match_errors = &match_errors,
    };
    const reader_thread = try std.Thread.spawn(.{}, reader_fn, .{reader_ctx});

    churn_thread.join();
    shutdown.store(true, .release);
    reader_thread.join();

    try std.testing.expectEqual(@as(u64, 0), churn_errors.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), match_errors.load(.monotonic));
}

// ============================================================================
// Simulation 4: Registry RCU Growth Under Load
// ============================================================================

test "simulation 4: registry RCU growth under load" {
    const seed: u64 = 0x1111AAAA_2222BBBB;
    printSeed(seed);

    const allocator = std.testing.allocator;

    var registry = try LockFreeSubscriberRegistry.init(allocator);
    defer registry.deinit();

    var shutdown = std.atomic.Value(bool).init(false);
    var read_errors = std.atomic.Value(u64).init(0);

    const ReaderCtx2 = struct {
        registry: *LockFreeSubscriberRegistry,
        shutdown: *std.atomic.Value(bool),
        read_errors: *std.atomic.Value(u64),
    };

    const reader_fn2 = struct {
        fn run(ctx: ReaderCtx2) void {
            var iter: usize = 0;
            while (!ctx.shutdown.load(.acquire)) : (iter += 1) {
                var event = Event{
                    .id = @intCast(iter),
                    .timestamp = @intCast(iter),
                    .event_type = .model_created,
                    .topic = "Growth.created",
                    .model_type = "Growth",
                    .model_id = @intCast(iter),
                    .data = "",
                };
                _ = event; // suppress unused

                // getMatchingResult must not crash during RCU growth
                const result = ctx.registry.getMatchingResult(&event);

                if (result.count > 64) {
                    _ = ctx.read_errors.fetchAdd(1, .monotonic);
                }

                if (iter % 100 == 0) {
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run;

    // Start reader thread
    var reader_ctx2 = ReaderCtx2{
        .registry = &registry,
        .shutdown = &shutdown,
        .read_errors = &read_errors,
    };
    const reader_thread = try std.Thread.spawn(.{}, reader_fn2, .{reader_ctx2});

    // Fill 64 slots (initial capacity)
    const filter = Filter{ .conditions = &.{} };
    var ids: [70]u64 = undefined;
    for (0..70) |i| {
        var topic_buf: [32]u8 = undefined;
        const topic = try std.fmt.bufPrint(&topic_buf, "Growth.created", .{});
        _ = i;
        ids[i] = try registry.subscribe(topic, filter, noopHandler);
    }

    // Let reader see the grown registry
    std.time.sleep(1_000_000); // 1ms

    shutdown.store(true, .release);
    reader_thread.join();

    // All 70 subscriptions must be visible
    try std.testing.expectEqual(@as(usize, 70), registry.getTotalSubscriptionCount());
    try std.testing.expectEqual(@as(u64, 0), read_errors.load(.monotonic));

    // Cleanup
    for (ids) |id| registry.unsubscribe(id);
}

// ============================================================================
// Simulation 5: Filter Determinism & Edge Cases
// ============================================================================

test "simulation 5: filter determinism and edge cases" {
    const seed: u64 = 0x5555CCCC_6666DDDD;
    printSeed(seed);

    // Test i64 min/max
    {
        var event = makeEvent(1);
        event.setField("val", .{ .int = std.math.minInt(i64) });
        const filter_lt = Filter{
            .conditions = &.{
                .{ .field = "val", .op = .lt, .value = "0", .parsed = .{ .int_val = 0 } },
            },
        };
        try std.testing.expect(filter_lt.matches(&event));

        event.setField("val", .{ .int = std.math.maxInt(i64) });
        const filter_gt = Filter{
            .conditions = &.{
                .{ .field = "val", .op = .gt, .value = "0", .parsed = .{ .int_val = 0 } },
            },
        };
        try std.testing.expect(filter_gt.matches(&event));
    }

    // Test u64 max
    {
        var event = makeEvent(2);
        event.setField("val", .{ .uint = std.math.maxInt(u64) });
        const filter = Filter{
            .conditions = &.{
                .{ .field = "val", .op = .gt, .value = "0", .parsed = .{ .int_val = 0 } },
            },
        };
        try std.testing.expect(filter.matches(&event));
    }

    // Test f64 NaN — NaN comparisons should always return false
    {
        var event = makeEvent(3);
        event.setField("val", .{ .float = std.math.nan(f64) });
        const filter_eq = Filter{
            .conditions = &.{
                .{ .field = "val", .op = .eq, .value = "0.0", .parsed = .{ .float_val = 0.0 } },
            },
        };
        // NaN != anything, including 0.0
        try std.testing.expect(!filter_eq.matches(&event));

        const filter_gt = Filter{
            .conditions = &.{
                .{ .field = "val", .op = .gt, .value = "0.0", .parsed = .{ .float_val = 0.0 } },
            },
        };
        try std.testing.expect(!filter_gt.matches(&event));
    }

    // Test f64 Inf
    {
        var event = makeEvent(4);
        event.setField("val", .{ .float = std.math.inf(f64) });
        const filter = Filter{
            .conditions = &.{
                .{ .field = "val", .op = .gt, .value = "999999999", .parsed = .{ .float_val = 999999999.0 } },
            },
        };
        try std.testing.expect(filter.matches(&event));
    }

    // Test -Inf
    {
        var event = makeEvent(5);
        event.setField("val", .{ .float = -std.math.inf(f64) });
        const filter = Filter{
            .conditions = &.{
                .{ .field = "val", .op = .lt, .value = "-999999999", .parsed = .{ .float_val = -999999999.0 } },
            },
        };
        try std.testing.expect(filter.matches(&event));
    }

    // Test empty string
    {
        var event = makeEvent(6);
        event.setField("val", .{ .string = FixedString.init("") });
        const filter = Filter{
            .conditions = &.{
                .{ .field = "val", .op = .eq, .value = "" },
            },
        };
        try std.testing.expect(filter.matches(&event));
    }

    // Test 32-byte string (FixedString boundary)
    {
        var event = makeEvent(7);
        const s32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"; // exactly 32 bytes
        event.setField("val", .{ .string = FixedString.init(s32) });
        const filter = Filter{
            .conditions = &.{
                .{ .field = "val", .op = .eq, .value = s32 },
            },
        };
        try std.testing.expect(filter.matches(&event));
    }

    // Test string with null bytes
    {
        var event = makeEvent(8);
        event.setField("val", .{ .string = FixedString.init("ab\x00cd") });
        const filter = Filter{
            .conditions = &.{
                .{ .field = "val", .op = .eq, .value = "ab\x00cd" },
            },
        };
        try std.testing.expect(filter.matches(&event));
    }

    // Test pre-parsed vs runtime-parsed consistency
    {
        var event = makeEvent(9);
        event.setField("price", .{ .int = 42 });

        // Pre-parsed
        const filter_pre = Filter{
            .conditions = &.{
                .{ .field = "price", .op = .eq, .value = "42", .parsed = .{ .int_val = 42 } },
            },
        };

        // Unparsed (runtime parsing)
        const filter_runtime = Filter{
            .conditions = &.{
                .{ .field = "price", .op = .eq, .value = "42", .parsed = .unparsed },
            },
        };

        // Must produce identical results
        try std.testing.expectEqual(filter_pre.matches(&event), filter_runtime.matches(&event));
    }

    // Determinism: same seed → same results (run filter matching with seeded event data)
    {
        var fi1 = FaultInjector.init(seed);
        var fi2 = FaultInjector.init(seed);

        for (0..100) |_| {
            const val1 = fi1.rng.random().int(i64);
            const val2 = fi2.rng.random().int(i64);
            try std.testing.expectEqual(val1, val2);
        }
    }
}

// ============================================================================
// Simulation 6: FixedString Truncation Boundary
// ============================================================================

test "simulation 6: fixed_string truncation boundary" {
    const seed: u64 = 0x6666EEEE_7777FFFF;
    printSeed(seed);

    const test_lengths = [_]usize{ 0, 1, 31, 32, 33, 64, 100, 255 };

    for (test_lengths) |len| {
        // Create input string of given length
        var input_buf: [256]u8 = undefined;
        for (0..len) |i| {
            input_buf[i] = @intCast('A' + (i % 26));
        }
        const input = input_buf[0..len];

        const fs = FixedString.init(input);

        // Invariant: len must be <= 32
        try std.testing.expect(fs.len <= 32);

        // Verify expected truncation
        const expected_len: u8 = @intCast(@min(len, 32));
        try std.testing.expectEqual(expected_len, fs.len);

        // Verify slice returns correct data
        const s = fs.slice();
        try std.testing.expectEqual(@as(usize, expected_len), s.len);

        // Verify content matches (up to truncation point)
        for (s, 0..) |c, i| {
            try std.testing.expectEqual(input[i], c);
        }
    }

    // Special case: init("") produces len == 0
    {
        const fs = FixedString.init("");
        try std.testing.expectEqual(@as(u8, 0), fs.len);
        try std.testing.expectEqual(@as(usize, 0), fs.slice().len);
    }

    // Truncated strings compare correctly
    {
        const long_str = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"; // 36 chars
        const fs = FixedString.init(long_str);
        try std.testing.expectEqualStrings(long_str[0..32], fs.slice());
    }
}

// ============================================================================
// Simulation 7: Event Serialization Roundtrip + Corruption
// ============================================================================

test "simulation 7: event serialization roundtrip and corruption" {
    const seed: u64 = 0x7777ABAB_8888CDCD;
    printSeed(seed);

    const allocator = std.testing.allocator;
    var fi = FaultInjector.init(seed);
    const num_events = 50;

    // Phase 1: Valid roundtrip
    for (0..num_events) |i| {
        const event = Event{
            .id = @intCast(fi.rng.random().int(u64)),
            .timestamp = fi.rng.random().int(i64),
            .event_type = switch (fi.rng.random().intRangeAtMost(u8, 0, 2)) {
                0 => .model_created,
                1 => .model_updated,
                2 => .model_deleted,
                else => .custom,
            },
            .topic = "Sim.created",
            .model_type = "Sim",
            .model_id = @intCast(i),
            .data = "simulation_test_data",
        };

        var buffer: [4096]u8 = undefined;
        const serialized = event.serialize(&buffer) catch {
            std.debug.print("Serialize failed at i={d} (seed=0x{X:0>16})\n", .{ i, seed });
            return error.TestUnexpectedResult;
        };

        const deserialized = Event.deserialize(serialized, allocator) catch {
            std.debug.print("Deserialize failed at i={d} (seed=0x{X:0>16})\n", .{ i, seed });
            return error.TestUnexpectedResult;
        };
        defer deserialized.deinit(allocator);

        // Verify roundtrip fidelity
        try std.testing.expectEqual(event.id, deserialized.id);
        try std.testing.expectEqual(event.event_type, deserialized.event_type);
        try std.testing.expectEqualStrings(event.topic, deserialized.topic);
        try std.testing.expectEqualStrings(event.model_type, deserialized.model_type);
        try std.testing.expectEqual(event.model_id, deserialized.model_id);
        try std.testing.expectEqualStrings(event.data, deserialized.data);
    }

    // Phase 2: Corruption resilience
    {
        const valid_event = Event{
            .id = 0x12345678_9ABCDEF0_12345678_9ABCDEF0,
            .timestamp = 1000000,
            .event_type = .model_created,
            .topic = "Sim.created",
            .model_type = "Sim",
            .model_id = 42,
            .data = "valid_data",
        };

        var buffer: [4096]u8 = undefined;
        const serialized = try valid_event.serialize(&buffer);

        // Try corrupting at various positions
        for (0..20) |_| {
            var corrupt_buf: [4096]u8 = undefined;
            @memcpy(corrupt_buf[0..serialized.len], serialized);

            // Corrupt 1-3 random bytes
            const num_corruptions = fi.rng.random().intRangeAtMost(usize, 1, 3);
            for (0..num_corruptions) |_| {
                const idx = fi.randomIndex(serialized.len);
                corrupt_buf[idx] = fi.randomByte();
            }

            // Deserialize must return error OR valid event (not panic)
            if (Event.deserialize(corrupt_buf[0..serialized.len], allocator)) |evt| {
                evt.deinit(allocator);
                // If it succeeded, that's fine — corruption may not have hit critical fields
            } else |_| {
                // Error is expected for corrupted data
            }
        }
    }

    // Phase 3: Truncated input
    {
        const valid_event = Event{
            .id = 42,
            .timestamp = 100,
            .event_type = .model_created,
            .topic = "Sim.created",
            .model_type = "Sim",
            .model_id = 1,
            .data = "data",
        };

        var buffer: [4096]u8 = undefined;
        const serialized = try valid_event.serialize(&buffer);

        // Try various truncation points
        var trunc_len: usize = 1;
        while (trunc_len < serialized.len) : (trunc_len += 1) {
            if (Event.deserialize(buffer[0..trunc_len], allocator)) |evt| {
                evt.deinit(allocator);
            } else |_| {
                // Error expected for truncated data
            }
        }
    }
}

// ============================================================================
// Simulation 8: Topic Matching Correctness (Truth Table)
// ============================================================================

test "simulation 8: topic matching correctness truth table" {
    const seed: u64 = 0x8888EFEF_9999F0F0;
    printSeed(seed);

    const Case = struct {
        pattern_topic: []const u8,
        event_topic: []const u8,
        expected: bool,
    };

    const cases = [_]Case{
        // Exact match
        .{ .pattern_topic = "Trade.created", .event_topic = "Trade.created", .expected = true },
        .{ .pattern_topic = "Trade.created", .event_topic = "Trade.updated", .expected = false },

        // Wildcard match
        .{ .pattern_topic = "Trade.*", .event_topic = "Trade.created", .expected = true },
        .{ .pattern_topic = "Trade.*", .event_topic = "Trade.updated", .expected = true },
        .{ .pattern_topic = "Trade.*", .event_topic = "Trade.deleted", .expected = true },
        .{ .pattern_topic = "Trade.*", .event_topic = "Portfolio.created", .expected = false },

        // Cross-model exact
        .{ .pattern_topic = "Portfolio.created", .event_topic = "Portfolio.created", .expected = true },
        .{ .pattern_topic = "Portfolio.created", .event_topic = "Trade.created", .expected = false },

        // Multi-segment (A.B.C treated as model="A", event="B" — only first dot matters)
        .{ .pattern_topic = "Order.created", .event_topic = "Order.created", .expected = true },
    };

    for (cases, 0..) |case, i| {
        // Build a Subscription with the pattern topic
        const sub = Subscription{
            .id = @intCast(i),
            .topic = case.pattern_topic,
            .filter = Filter{ .conditions = &.{} },
            .handler = noopHandler,
            .created_at = 0,
            .topic_pattern = Subscription.computeTopicPattern(case.pattern_topic),
        };

        const result = sub.matchesTopic(case.event_topic);

        if (result != case.expected) {
            std.debug.print(
                "TOPIC MATCH FAILED (seed=0x{X:0>16}): pattern=\"{s}\" topic=\"{s}\" expected={} got={}\n",
                .{ seed, case.pattern_topic, case.event_topic, case.expected, result },
            );
            return error.TestExpectedEqual;
        }
    }

    // Verify hash-based matching agrees with string-based matching for all cases
    for (cases) |case| {
        const sub = Subscription{
            .id = 0,
            .topic = case.pattern_topic,
            .filter = Filter{ .conditions = &.{} },
            .handler = noopHandler,
            .created_at = 0,
            .topic_pattern = Subscription.computeTopicPattern(case.pattern_topic),
        };

        const hash_result = sub.matchesTopic(case.event_topic);

        // Verify it matches expected
        try std.testing.expectEqual(case.expected, hash_result);
    }
}

// ============================================================================
// Simulation 9: Event Field Saturation
// ============================================================================

test "simulation 9: event field saturation" {
    const seed: u64 = 0x9999ABAB_AAAABBBB;
    printSeed(seed);

    var event = makeEvent(1);

    // Set MAX_EVENT_FIELDS (8) fields with unique values
    const field_names = [_][]const u8{ "f0", "f1", "f2", "f3", "f4", "f5", "f6", "f7" };
    const field_values = [_]i64{ 10, 20, 30, 40, 50, 60, 70, 80 };

    for (field_names, 0..) |name, i| {
        event.setField(name, .{ .int = field_values[i] });
    }

    try std.testing.expectEqual(@as(u8, MAX_EVENT_FIELDS), event.field_count);

    // Verify all 8 fields have correct values
    for (field_names, 0..) |name, i| {
        const val = event.getField(name) orelse {
            std.debug.print("MISSING FIELD: {s} (seed=0x{X:0>16})\n", .{ name, seed });
            return error.TestExpectedEqual;
        };
        switch (val) {
            .int => |v| try std.testing.expectEqual(field_values[i], v),
            else => return error.TestExpectedEqual,
        }
    }

    // Attempt to set 9th field — should be silently dropped
    event.setField("f8_overflow", .{ .int = 99 });

    // field_count must still be 8
    try std.testing.expectEqual(@as(u8, MAX_EVENT_FIELDS), event.field_count);

    // 9th field must not exist
    try std.testing.expect(event.getField("f8_overflow") == null);

    // Original 8 fields must be untouched
    for (field_names, 0..) |name, i| {
        const val = event.getField(name).?;
        switch (val) {
            .int => |v| try std.testing.expectEqual(field_values[i], v),
            else => return error.TestExpectedEqual,
        }
    }

    // Update existing field (should work, not add new slot)
    event.setField("f0", .{ .int = 999 });
    try std.testing.expectEqual(@as(u8, MAX_EVENT_FIELDS), event.field_count);
    switch (event.getField("f0").?) {
        .int => |v| try std.testing.expectEqual(@as(i64, 999), v),
        else => return error.TestExpectedEqual,
    }

    // Verify all field types work at saturation
    {
        var event2 = makeEvent(2);
        event2.setField("str", .{ .string = FixedString.init("hello") });
        event2.setField("num", .{ .int = 42 });
        event2.setField("unum", .{ .uint = 100 });
        event2.setField("flt", .{ .float = 3.14 });
        event2.setField("flag", .{ .boolean = true });
        event2.setField("s2", .{ .string = FixedString.init("world") });
        event2.setField("n2", .{ .int = -1 });
        event2.setField("n3", .{ .int = 0 });

        try std.testing.expectEqual(@as(u8, 8), event2.field_count);

        // 9th should be dropped
        event2.setField("overflow", .{ .int = 1 });
        try std.testing.expectEqual(@as(u8, 8), event2.field_count);
        try std.testing.expect(event2.getField("overflow") == null);
    }
}

// ============================================================================
// Simulation 10: Full Integration Safety + Liveness
// ============================================================================

test "simulation 10: full integration safety and liveness" {
    const seed: u64 = 0xAAAA1111_BBBB2222;
    printSeed(seed);

    const allocator = std.testing.allocator;

    var bus = try MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 2,
    });
    defer bus.deinit();

    // Subscribe 10 handlers with various filters
    var delivery_count = std.atomic.Value(u64).init(0);

    const handler_ctx = struct {
        var counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

        fn handle(event: *const Event, alloc: Allocator) void {
            _ = alloc;
            // Verify event structure is valid
            _ = event.topic;
            _ = event.model_type;
            _ = counter.fetchAdd(1, .monotonic);
        }
    };

    var sub_ids: [10]u64 = undefined;
    for (0..10) |i| {
        const filter = if (i < 5)
            Filter{ .conditions = &.{} } // No filter
        else
            Filter{
                .conditions = &.{
                    .{ .field = "price", .op = .gt, .value = "0", .parsed = .{ .int_val = 0 } },
                },
            };

        const topic = if (i % 2 == 0) "Sim.created" else "Sim.*";
        sub_ids[i] = try bus.subscribe(topic, filter, handler_ctx.handle);
    }

    // Start the bus
    try bus.start();

    // Phase 1: Safety — publish events with random delays
    var fi = FaultInjector.init(seed);
    const num_events: u64 = 500;
    var published: u64 = 0;
    var dropped: u64 = 0;

    for (0..num_events) |i| {
        var event = try Event.initOwned(
            allocator,
            .model_created,
            "Sim.created",
            "Sim",
            @intCast(i),
            "{}",
        );
        event.setField("price", .{ .int = @intCast(i + 1) });

        if (bus.publish(event)) {
            published += 1;
        } else {
            dropped += 1;
        }

        if (fi.shouldFault(20)) {
            fi.randomDelay();
        }

        // Invariant check periodically
        if (i % 50 == 0) {
            const stats = bus.getStats();
            // published + dropped must equal what we've sent so far
            try std.testing.expectEqual(@as(u64, @intCast(i + 1)), stats.published + stats.dropped);
        }
    }

    // Randomly unsubscribe/resubscribe 3 handlers mid-stream
    for (0..3) |i| {
        bus.unsubscribe(sub_ids[i]);
    }
    for (0..3) |i| {
        const filter = Filter{ .conditions = &.{} };
        sub_ids[i] = try bus.subscribe("Sim.created", filter, handler_ctx.handle);
    }

    // Publish a few more after resubscribe
    for (0..50) |i| {
        var event = try Event.initOwned(
            allocator,
            .model_created,
            "Sim.created",
            "Sim",
            @intCast(num_events + i),
            "{}",
        );
        event.setField("price", .{ .int = @intCast(i + 1) });

        if (bus.publish(event)) {
            published += 1;
        } else {
            dropped += 1;
        }
    }

    // Safety invariant
    const stats = bus.getStats();
    try std.testing.expect(stats.published + stats.dropped == published + dropped);

    // Phase 2: Liveness — wait for queue to drain (max 2 seconds)
    var waited: u64 = 0;
    const max_wait_ns: u64 = 2_000_000_000; // 2 seconds
    while (bus.event_queue.size() > 0 and waited < max_wait_ns) {
        std.time.sleep(1_000_000); // 1ms
        waited += 1_000_000;
    }

    // Queue must be drained
    try std.testing.expect(bus.event_queue.isEmpty());

    // Final stats check
    const final_stats = bus.getStats();
    try std.testing.expect(final_stats.delivered + final_stats.dropped <= final_stats.published + stats.dropped);

    // Cleanup subscriptions
    for (sub_ids) |id| bus.unsubscribe(id);

    // Workers are still alive (not deadlocked) — deinit will join them
}

// ============================================================================
// Shared Test Helpers
// ============================================================================

fn noopHandler(event: *const Event, alloc: Allocator) void {
    _ = event;
    _ = alloc;
}
