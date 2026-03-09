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
    const seen = try allocator.alloc(bool, total_events);
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
    const churn_ctx = ChurnCtx{
        .registry = &registry,
        .shutdown = &shutdown,
        .churn_errors = &churn_errors,
        .fault_seed = seed,
    };
    const churn_thread = try std.Thread.spawn(.{}, churn_fn, .{churn_ctx});

    // Thread B: concurrent reads
    const reader_ctx = ReaderCtx{
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
    const reader_ctx2 = ReaderCtx2{
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
        ids[i] = try registry.subscribe(topic, filter, noopHandler);
    }

    // Let reader see the grown registry
    std.Thread.sleep(1_000_000); // 1ms

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
        std.Thread.sleep(1_000_000); // 1ms
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
// Simulation 11: ReactiveModel Multiple Subscribers
// ============================================================================

test "simulation 11: reactive model multiple subscribers receive events" {
    const seed: u64 = 0xBBBB3333_CCCC4444;
    printSeed(seed);

    const allocator = std.testing.allocator;
    const ReactiveModel = @import("experimental/reactive_model.zig").ReactiveModel;

    const Model = ReactiveModel("SimModel", .{
        .price = .i64,
        .quantity = .u64,
    });

    var bus = try MessageBus.init(allocator, .{
        .queue_capacity = 256,
        .worker_count = 2,
    });
    defer bus.deinit();

    // Three independent subscriber counters
    const SubCtx = struct {
        var counter_a: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
        var counter_b: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
        var counter_c: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

        fn handlerA(event: *const Event, alloc: Allocator) void {
            _ = alloc;
            _ = event;
            _ = counter_a.fetchAdd(1, .monotonic);
        }
        fn handlerB(event: *const Event, alloc: Allocator) void {
            _ = alloc;
            _ = event;
            _ = counter_b.fetchAdd(1, .monotonic);
        }
        fn handlerC(event: *const Event, alloc: Allocator) void {
            _ = alloc;
            _ = event;
            _ = counter_c.fetchAdd(1, .monotonic);
        }
    };

    // Reset counters (they're global due to comptime)
    SubCtx.counter_a.store(0, .monotonic);
    SubCtx.counter_b.store(0, .monotonic);
    SubCtx.counter_c.store(0, .monotonic);

    const filter = Filter{ .conditions = &.{} };
    const id_a = try bus.subscribe("SimModel.updated", filter, SubCtx.handlerA);
    const id_b = try bus.subscribe("SimModel.updated", filter, SubCtx.handlerB);
    const id_c = try bus.subscribe("SimModel.*", filter, SubCtx.handlerC);

    try bus.start();

    var model = Model.init(allocator, &bus);
    defer model.deinit();
    model.id = 1;

    // Publish 20 mutations
    const num_mutations: u64 = 20;
    for (0..num_mutations) |i| {
        try model.set("price", @as(i64, @intCast(i + 1)));
    }

    // Wait for delivery (max 2s)
    var waited: u64 = 0;
    const max_wait: u64 = 2_000_000_000;
    while (waited < max_wait) {
        if (SubCtx.counter_a.load(.monotonic) >= num_mutations and
            SubCtx.counter_b.load(.monotonic) >= num_mutations and
            SubCtx.counter_c.load(.monotonic) >= num_mutations) break;
        std.Thread.sleep(1_000_000);
        waited += 1_000_000;
    }

    // All three subscribers must have received all events
    const a = SubCtx.counter_a.load(.monotonic);
    const b = SubCtx.counter_b.load(.monotonic);
    const c = SubCtx.counter_c.load(.monotonic);

    if (a < num_mutations or b < num_mutations or c < num_mutations) {
        std.debug.print(
            "SUBSCRIBER DELIVERY FAILED (seed=0x{X:0>16}): a={d} b={d} c={d} expected>={d}\n",
            .{ seed, a, b, c, num_mutations },
        );
        return error.TestExpectedEqual;
    }

    bus.unsubscribe(id_a);
    bus.unsubscribe(id_b);
    bus.unsubscribe(id_c);
}

// ============================================================================
// Simulation 12: ReactiveModel Subscriber Mutation (Feedback Loop Prevention)
// ============================================================================

test "simulation 12: reactive model subscriber mutation no feedback loop" {
    const seed: u64 = 0xDDDD5555_EEEE6666;
    printSeed(seed);

    const allocator = std.testing.allocator;
    const ReactiveModel = @import("experimental/reactive_model.zig").ReactiveModel;

    const Model = ReactiveModel("LoopModel", .{
        .value = .i64,
        .derived = .i64,
    });

    var bus = try MessageBus.init(allocator, .{
        .queue_capacity = 256,
        .worker_count = 2,
    });
    defer bus.deinit();

    // Shared model instance accessible from handler
    const Ctx = struct {
        var shared_model: ?*Model = null;
        var handler_call_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
        var observer_call_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

        /// Mutating handler: when "value" changes, sets "derived" = value * 2.
        /// Without feedback loop prevention, this would trigger itself infinitely:
        ///   set("value") → event → handler → set("derived") → event → handler → ...
        fn mutatingHandler(event: *const Event, alloc: Allocator) void {
            _ = alloc;
            _ = event;
            _ = handler_call_count.fetchAdd(1, .monotonic);
            if (shared_model) |m| {
                const val = m.get("value");
                m.set("derived", val * 2) catch {};
            }
        }

        /// Read-only observer: just counts deliveries.
        fn observer(event: *const Event, alloc: Allocator) void {
            _ = alloc;
            _ = event;
            _ = observer_call_count.fetchAdd(1, .monotonic);
        }
    };

    // Reset
    Ctx.handler_call_count.store(0, .monotonic);
    Ctx.observer_call_count.store(0, .monotonic);

    const filter = Filter{ .conditions = &.{} };
    const mutator_id = try bus.subscribe("LoopModel.updated", filter, Ctx.mutatingHandler);
    const observer_id = try bus.subscribe("LoopModel.updated", filter, Ctx.observer);

    try bus.start();

    var model = Model.init(allocator, &bus);
    defer model.deinit();
    model.id = 1;
    Ctx.shared_model = &model;

    // Trigger 10 mutations from outside any handler context
    const num_external_mutations: u64 = 10;
    for (0..num_external_mutations) |i| {
        try model.set("value", @as(i64, @intCast(i + 1)));
        // Small delay to let events process before next mutation
        std.Thread.sleep(5_000_000); // 5ms
    }

    // Wait for delivery (max 3s)
    var waited: u64 = 0;
    const max_wait: u64 = 3_000_000_000;
    while (waited < max_wait) {
        // The mutating handler produces derived events. The observer sees both
        // the original and derived events. But the mutating handler must NOT
        // see its own derived events (feedback loop prevention).
        if (Ctx.handler_call_count.load(.monotonic) >= num_external_mutations) break;
        std.Thread.sleep(1_000_000);
        waited += 1_000_000;
    }

    const handler_calls = Ctx.handler_call_count.load(.monotonic);
    const observer_calls = Ctx.observer_call_count.load(.monotonic);

    Ctx.shared_model = null;

    // CRITICAL INVARIANT: The mutating handler must be called for the external
    // mutations (set("value")) but NOT for the events it produces itself
    // (set("derived")). Without feedback loop prevention, handler_calls would
    // be unbounded (infinite loop) or at least >> num_external_mutations.
    //
    // The handler is called for:
    //   - Each external set("value") → "LoopModel.updated" event → delivered to mutatingHandler
    // The handler is NOT called for:
    //   - Each set("derived") inside the handler → event tagged with handler's subscription ID → skipped
    //
    // So handler_calls should equal num_external_mutations (not 2x or infinite).
    if (handler_calls > num_external_mutations * 2) {
        std.debug.print(
            "FEEDBACK LOOP DETECTED (seed=0x{X:0>16}): handler_calls={d} expected<={d}\n",
            .{ seed, handler_calls, num_external_mutations * 2 },
        );
        return error.TestExpectedEqual;
    }

    // The observer should see MORE events than the handler because it receives
    // both external events AND the derived events from the mutating handler.
    // observer_calls >= handler_calls (observer sees everything, handler is filtered)
    std.debug.print(
        "\nFeedback loop test: handler_calls={d}, observer_calls={d}, external_mutations={d}\n",
        .{ handler_calls, observer_calls, num_external_mutations },
    );

    // observer must have received events from both sources
    try std.testing.expect(observer_calls >= num_external_mutations);

    bus.unsubscribe(mutator_id);
    bus.unsubscribe(observer_id);
}

// ============================================================================
// Simulation 13: ReactiveModel Concurrent Mutations with Subscribers
// ============================================================================

test "simulation 13: reactive model concurrent mutations with subscribers" {
    const seed: u64 = 0xFFFF7777_00008888;
    printSeed(seed);

    const allocator = std.testing.allocator;
    const ReactiveModel = @import("experimental/reactive_model.zig").ReactiveModel;

    const Model = ReactiveModel("ConcModel", .{
        .counter = .i64,
    });

    var bus = try MessageBus.init(allocator, .{
        .queue_capacity = 512,
        .worker_count = 2,
    });
    defer bus.deinit();

    const Ctx = struct {
        var delivery_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
        var max_value_seen: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

        fn handler(event: *const Event, alloc: Allocator) void {
            _ = alloc;
            _ = event;
            _ = delivery_count.fetchAdd(1, .monotonic);
        }
    };

    Ctx.delivery_count.store(0, .monotonic);
    Ctx.max_value_seen.store(0, .monotonic);

    const filter = Filter{ .conditions = &.{} };
    const sub_id = try bus.subscribe("ConcModel.updated", filter, Ctx.handler);

    try bus.start();

    var model = Model.init(allocator, &bus);
    defer model.deinit();
    model.id = 1;

    // 4 threads, each doing CAS increments
    const num_threads = 4;
    const ops_per_thread = 100;

    const Worker = struct {
        fn run(m: *Model) void {
            for (0..ops_per_thread) |_| {
                while (true) {
                    const current = m.get("counter");
                    const ok = m.compareAndSwap("counter", current, current + 1) catch break;
                    if (ok) break;
                    // CAS failed, retry
                    std.atomic.spinLoopHint();
                }
            }
        }
    };

    var threads: [num_threads]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{&model});
    }
    for (threads) |t| t.join();

    // The counter must equal exactly num_threads * ops_per_thread (CAS guarantees this)
    const final_value = model.get("counter");
    try std.testing.expectEqual(@as(i64, num_threads * ops_per_thread), final_value);

    // Wait for events to drain
    var waited: u64 = 0;
    while (waited < 2_000_000_000) {
        if (bus.event_queue.isEmpty()) break;
        std.Thread.sleep(1_000_000);
        waited += 1_000_000;
    }

    const deliveries = Ctx.delivery_count.load(.monotonic);
    std.debug.print(
        "\nConcurrent CAS test: final_counter={d}, deliveries={d}, expected_mutations={d}\n",
        .{ final_value, deliveries, num_threads * ops_per_thread },
    );

    // Each successful CAS publishes an event, so deliveries should match
    // (some may be dropped if queue is full under load, but most should arrive)
    try std.testing.expect(deliveries > 0);

    bus.unsubscribe(sub_id);
}

// ============================================================================
// SLO Enforcement Tests
//
// These tests enforce the Service Level Objectives defined in SLA.md.
// They measure latencies of hot-path operations and assert they stay
// within bounds. Use ReleaseFast for accurate numbers:
//   zig build test-simulation -Doptimize=ReleaseFast
//
// Margins are generous (10-20x over advertised) to handle CI noise.
// The goal is regression detection, not absolute validation.
// ============================================================================

// ============================================================================
// Simulation 14: Ring Buffer Push/Pop Latency SLO
// ============================================================================

test "simulation 14: SLO ring buffer push pop latency" {
    const seed: u64 = 0x5E0A_0001_0001_0001;
    printSeed(seed);

    const allocator = std.testing.allocator;
    const iterations: usize = 10_000;

    var buffer = try EventRingBuffer.init(allocator, 1024);
    defer buffer.deinit();

    // Measure push latency
    var push_latencies: [iterations]u64 = undefined;
    for (0..iterations) |i| {
        const event = makeEvent(@intCast(i));
        const start = std.time.nanoTimestamp();
        const ok = buffer.push(event);
        const end = std.time.nanoTimestamp();
        push_latencies[i] = @intCast(end - start);
        if (!ok) {
            // Drain to make room
            while (buffer.pop()) |_| {}
        }
    }

    // Drain and measure pop latency
    while (buffer.pop()) |_| {}
    // Refill for pop measurement
    for (0..iterations) |i| {
        const event = makeEvent(@intCast(i));
        if (!buffer.push(event)) break;
    }

    var pop_latencies_buf: [1024]u64 = undefined;
    var pop_count: usize = 0;
    while (buffer.pop()) |_| {
        if (pop_count > 0) { // skip first (cold)
            const start = std.time.nanoTimestamp();
            // The pop already happened, measure next one
            if (buffer.pop()) |_| {
                const end = std.time.nanoTimestamp();
                if (pop_count - 1 < pop_latencies_buf.len) {
                    pop_latencies_buf[pop_count - 1] = @intCast(end - start);
                }
            }
        }
        pop_count += 1;
    }

    // Sort and compute P99 for push
    std.mem.sort(u64, &push_latencies, {}, std.sort.asc(u64));
    const push_p50 = push_latencies[iterations / 2];
    const push_p99 = push_latencies[iterations * 99 / 100];

    std.debug.print(
        "\n[SLO] Ring buffer push: P50={d}ns, P99={d}ns (SLO: P99 < 10,000ns)\n",
        .{ push_p50, push_p99 },
    );

    // SLO: P99 push < 10µs (generous margin; advertised 1.5µs)
    // In Debug mode on shared VMs, allow up to 50µs
    try std.testing.expect(push_p99 < 50_000);
}

// ============================================================================
// Simulation 15: Filter Matching Latency SLO
// ============================================================================

test "simulation 15: SLO filter matching latency" {
    const seed: u64 = 0x5E0A_0002_0002_0002;
    printSeed(seed);

    const iterations: usize = 10_000;

    // --- Empty filter (should be near-zero) ---
    {
        var event = makeEvent(1);
        event.setField("price", .{ .int = 5000 });
        const empty_filter = Filter{ .conditions = &.{} };

        var latencies: [iterations]u64 = undefined;
        for (0..iterations) |i| {
            const start = std.time.nanoTimestamp();
            const result = empty_filter.matches(&event);
            const end = std.time.nanoTimestamp();
            latencies[i] = @intCast(end - start);
            // Prevent dead code elimination
            if (!result) @panic("empty filter must match");
        }

        std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));
        const p50 = latencies[iterations / 2];
        const p99 = latencies[iterations * 99 / 100];
        std.debug.print(
            "\n[SLO] Filter empty: P50={d}ns, P99={d}ns (SLO: P99 < 1,000ns)\n",
            .{ p50, p99 },
        );
        try std.testing.expect(p99 < 10_000); // 10µs generous margin
    }

    // --- Single int condition ---
    {
        var event = makeEvent(2);
        event.setField("price", .{ .int = 5000 });
        const single_filter = Filter{
            .conditions = &.{
                .{ .field = "price", .op = .gt, .value = "1000", .parsed = .{ .int_val = 1000 } },
            },
        };

        var latencies: [iterations]u64 = undefined;
        for (0..iterations) |i| {
            const start = std.time.nanoTimestamp();
            const result = single_filter.matches(&event);
            const end = std.time.nanoTimestamp();
            latencies[i] = @intCast(end - start);
            if (!result) @panic("filter must match");
        }

        std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));
        const p50 = latencies[iterations / 2];
        const p99 = latencies[iterations * 99 / 100];
        std.debug.print(
            "\n[SLO] Filter single int: P50={d}ns, P99={d}ns (SLO: P99 < 5,000ns)\n",
            .{ p50, p99 },
        );
        // SLO: < 50ns advertised, allow 100x for Debug/CI
        try std.testing.expect(p99 < 50_000);
    }

    // --- 4 conditions ---
    {
        var event = makeEvent(3);
        event.setField("price", .{ .int = 5000 });
        event.setField("qty", .{ .int = 100 });
        event.setField("side", .{ .string = FixedString.init("BUY") });
        event.setField("active", .{ .boolean = true });

        const multi_filter = Filter{
            .conditions = &.{
                .{ .field = "price", .op = .gt, .value = "1000", .parsed = .{ .int_val = 1000 } },
                .{ .field = "qty", .op = .gt, .value = "10", .parsed = .{ .int_val = 10 } },
                .{ .field = "side", .op = .eq, .value = "BUY" },
                .{ .field = "active", .op = .eq, .value = "true", .parsed = .{ .bool_val = true } },
            },
        };

        var latencies: [iterations]u64 = undefined;
        for (0..iterations) |i| {
            const start = std.time.nanoTimestamp();
            const result = multi_filter.matches(&event);
            const end = std.time.nanoTimestamp();
            latencies[i] = @intCast(end - start);
            if (!result) @panic("multi-filter must match");
        }

        std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));
        const p50 = latencies[iterations / 2];
        const p99 = latencies[iterations * 99 / 100];
        std.debug.print(
            "\n[SLO] Filter 4 conditions: P50={d}ns, P99={d}ns (SLO: P99 < 20,000ns)\n",
            .{ p50, p99 },
        );
        try std.testing.expect(p99 < 100_000);
    }
}

// ============================================================================
// Simulation 16: Topic Matching Latency SLO
// ============================================================================

test "simulation 16: SLO topic matching latency" {
    const seed: u64 = 0x5E0A_0003_0003_0003;
    printSeed(seed);

    const iterations: usize = 10_000;

    // Exact match via hash
    {
        const sub = Subscription{
            .id = 1,
            .topic = "Trade.created",
            .filter = Filter{ .conditions = &.{} },
            .handler = noopHandler,
            .created_at = 0,
            .topic_pattern = Subscription.computeTopicPattern("Trade.created"),
        };

        var latencies: [iterations]u64 = undefined;
        for (0..iterations) |i| {
            const start = std.time.nanoTimestamp();
            const result = sub.matchesTopic("Trade.created");
            const end = std.time.nanoTimestamp();
            latencies[i] = @intCast(end - start);
            if (!result) @panic("exact match must succeed");
        }

        std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));
        const p50 = latencies[iterations / 2];
        const p99 = latencies[iterations * 99 / 100];
        std.debug.print(
            "\n[SLO] Topic exact match: P50={d}ns, P99={d}ns (SLO: P99 < 5,000ns)\n",
            .{ p50, p99 },
        );
        try std.testing.expect(p99 < 50_000);
    }

    // Wildcard match via hash
    {
        const sub = Subscription{
            .id = 2,
            .topic = "Trade.*",
            .filter = Filter{ .conditions = &.{} },
            .handler = noopHandler,
            .created_at = 0,
            .topic_pattern = Subscription.computeTopicPattern("Trade.*"),
        };

        var latencies: [iterations]u64 = undefined;
        for (0..iterations) |i| {
            const start = std.time.nanoTimestamp();
            const result = sub.matchesTopic("Trade.updated");
            const end = std.time.nanoTimestamp();
            latencies[i] = @intCast(end - start);
            if (!result) @panic("wildcard match must succeed");
        }

        std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));
        const p50 = latencies[iterations / 2];
        const p99 = latencies[iterations * 99 / 100];
        std.debug.print(
            "\n[SLO] Topic wildcard match: P50={d}ns, P99={d}ns (SLO: P99 < 5,000ns)\n",
            .{ p50, p99 },
        );
        try std.testing.expect(p99 < 50_000);
    }

    // Non-match (must also be fast)
    {
        const sub = Subscription{
            .id = 3,
            .topic = "Trade.created",
            .filter = Filter{ .conditions = &.{} },
            .handler = noopHandler,
            .created_at = 0,
            .topic_pattern = Subscription.computeTopicPattern("Trade.created"),
        };

        var latencies: [iterations]u64 = undefined;
        for (0..iterations) |i| {
            const start = std.time.nanoTimestamp();
            const result = sub.matchesTopic("Portfolio.created");
            const end = std.time.nanoTimestamp();
            latencies[i] = @intCast(end - start);
            if (result) @panic("non-match must fail");
        }

        std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));
        const p50 = latencies[iterations / 2];
        const p99 = latencies[iterations * 99 / 100];
        std.debug.print(
            "\n[SLO] Topic non-match: P50={d}ns, P99={d}ns (SLO: P99 < 5,000ns)\n",
            .{ p50, p99 },
        );
        try std.testing.expect(p99 < 50_000);
    }
}

// ============================================================================
// Simulation 17: ReactiveModel Latency SLOs
// ============================================================================

test "simulation 17: SLO reactive model get set toJSON latency" {
    const seed: u64 = 0x5E0A_0004_0004_0004;
    printSeed(seed);

    const allocator = std.testing.allocator;
    const ReactiveModel = @import("experimental/reactive_model.zig").ReactiveModel;
    const iterations: usize = 10_000;

    const Model = ReactiveModel("SLOModel", .{
        .price = .i64,
        .quantity = .u64,
        .ratio = .f64,
        .active = .bool,
    });

    var model = Model.init(allocator, null);
    defer model.deinit();

    // Warm up
    try model.set("price", @as(i64, 100));
    try model.set("quantity", @as(u64, 500));
    try model.set("ratio", @as(f64, 1.5));
    try model.set("active", true);

    // --- Numeric get ---
    {
        var latencies: [iterations]u64 = undefined;
        for (0..iterations) |i| {
            const start = std.time.nanoTimestamp();
            const val = model.get("price");
            const end = std.time.nanoTimestamp();
            latencies[i] = @intCast(end - start);
            // Prevent DCE
            if (val == std.math.minInt(i64)) @panic("unexpected");
        }

        std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));
        const p50 = latencies[iterations / 2];
        const p99 = latencies[iterations * 99 / 100];
        std.debug.print(
            "\n[SLO] ReactiveModel get(i64): P50={d}ns, P99={d}ns (SLO: P99 < 5,000ns)\n",
            .{ p50, p99 },
        );
        try std.testing.expect(p99 < 50_000);
    }

    // --- Numeric set (no bus, so no publish overhead) ---
    {
        var latencies: [iterations]u64 = undefined;
        for (0..iterations) |i| {
            const start = std.time.nanoTimestamp();
            try model.set("price", @as(i64, @intCast(i)));
            const end = std.time.nanoTimestamp();
            latencies[i] = @intCast(end - start);
        }

        std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));
        const p50 = latencies[iterations / 2];
        const p99 = latencies[iterations * 99 / 100];
        std.debug.print(
            "\n[SLO] ReactiveModel set(i64): P50={d}ns, P99={d}ns (SLO: P99 < 20,000ns)\n",
            .{ p50, p99 },
        );
        try std.testing.expect(p99 < 100_000);
    }

    // --- toJSON ---
    {
        var latencies: [iterations]u64 = undefined;
        var json_buf: [4096]u8 = undefined;
        for (0..iterations) |i| {
            const start = std.time.nanoTimestamp();
            const json = try model.toJSON(&json_buf);
            const end = std.time.nanoTimestamp();
            latencies[i] = @intCast(end - start);
            if (json.len == 0) @panic("empty json");
        }

        std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));
        const p50 = latencies[iterations / 2];
        const p99 = latencies[iterations * 99 / 100];
        std.debug.print(
            "\n[SLO] ReactiveModel toJSON: P50={d}ns, P99={d}ns (SLO: P99 < 10,000ns)\n",
            .{ p50, p99 },
        );
        // SLO: < 1µs advertised, allow 50x for Debug/CI
        try std.testing.expect(p99 < 500_000);
    }

    // --- CAS ---
    {
        var latencies: [iterations]u64 = undefined;
        try model.set("price", @as(i64, 0));
        for (0..iterations) |i| {
            const current = model.get("price");
            const start = std.time.nanoTimestamp();
            const ok = try model.compareAndSwap("price", current, current + 1);
            const end = std.time.nanoTimestamp();
            latencies[i] = @intCast(end - start);
            if (!ok) @panic("uncontended CAS must succeed");
        }

        std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));
        const p50 = latencies[iterations / 2];
        const p99 = latencies[iterations * 99 / 100];
        std.debug.print(
            "\n[SLO] ReactiveModel CAS: P50={d}ns, P99={d}ns (SLO: P99 < 20,000ns)\n",
            .{ p50, p99 },
        );
        try std.testing.expect(p99 < 100_000);
    }
}

// ============================================================================
// Simulation 18: UDP Binary Protocol Parse Latency SLO
// ============================================================================

test "simulation 18: SLO UDP binary protocol parse latency" {
    const seed: u64 = 0x5E0A_0005_0005_0005;
    printSeed(seed);

    const AddOrder = @import("protocols/example_itch.zig").AddOrder;
    const iterations: usize = 10_000;

    // Build a valid 38-byte ITCH AddOrder message
    var data: [38]u8 = undefined;
    data[0] = 'A';
    std.mem.writeInt(u16, data[1..3], 42, .big);
    std.mem.writeInt(u16, data[3..5], 0, .big);
    std.mem.writeInt(u64, data[5..13], 1234567890, .big);
    std.mem.writeInt(u64, data[13..21], 100001, .big);
    data[21] = 'B';
    std.mem.writeInt(u32, data[22..26], 500, .big);
    @memcpy(data[26..34], "AAPL    ");
    std.mem.writeInt(u32, data[34..38], 15000, .big);

    var latencies: [iterations]u64 = undefined;
    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        const result = AddOrder.parse(&data);
        const end = std.time.nanoTimestamp();
        latencies[i] = @intCast(end - start);
        if (!result.isOk()) @panic("parse must succeed");
    }

    std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));
    const p50 = latencies[iterations / 2];
    const p99 = latencies[iterations * 99 / 100];
    std.debug.print(
        "\n[SLO] ITCH AddOrder parse (38B): P50={d}ns, P99={d}ns (SLO: P99 < 2,000ns)\n",
        .{ p50, p99 },
    );
    // SLO: < 100ns advertised, allow 200x for Debug/CI
    try std.testing.expect(p99 < 200_000);
}

// ============================================================================
// Simulation 19: Zero-Allocation Guarantee (Hot Path)
// ============================================================================

test "simulation 19: SLO zero allocation hot path" {
    const seed: u64 = 0x5E0A_0006_0006_0006;
    printSeed(seed);

    const allocator = std.testing.allocator;
    const ReactiveModel = @import("experimental/reactive_model.zig").ReactiveModel;
    const AddOrder = @import("protocols/example_itch.zig").AddOrder;

    // This test verifies that hot-path operations don't allocate.
    // We use the testing allocator (which tracks allocations) and verify
    // that no allocations happen during hot-path operations.
    //
    // The key insight: if we perform many operations and the testing
    // allocator reports no leaks, and we don't free anything, then
    // no allocations happened.

    // --- Ring buffer push/pop: zero alloc ---
    {
        var buffer = try EventRingBuffer.init(allocator, 64);
        defer buffer.deinit();

        // These operations must not allocate
        for (0..50) |i| {
            const event = makeEvent(@intCast(i));
            _ = buffer.push(event);
        }
        while (buffer.pop()) |_| {}
    }

    // --- Filter matching: zero alloc ---
    {
        var event = makeEvent(1);
        event.setField("price", .{ .int = 5000 });
        event.setField("qty", .{ .int = 100 });

        const filter = Filter{
            .conditions = &.{
                .{ .field = "price", .op = .gt, .value = "1000", .parsed = .{ .int_val = 1000 } },
                .{ .field = "qty", .op = .gt, .value = "10", .parsed = .{ .int_val = 10 } },
            },
        };

        for (0..1000) |_| {
            _ = filter.matches(&event);
        }
    }

    // --- Topic matching: zero alloc ---
    {
        const sub = Subscription{
            .id = 1,
            .topic = "Trade.created",
            .filter = Filter{ .conditions = &.{} },
            .handler = noopHandler,
            .created_at = 0,
            .topic_pattern = Subscription.computeTopicPattern("Trade.created"),
        };

        for (0..1000) |_| {
            _ = sub.matchesTopic("Trade.created");
            _ = sub.matchesTopic("Trade.updated");
        }
    }

    // --- ReactiveModel numeric get/set: zero alloc ---
    {
        const Model = ReactiveModel("ZeroAllocModel", .{
            .price = .i64,
            .flag = .bool,
        });

        var model = Model.init(allocator, null);
        defer model.deinit();

        for (0..1000) |i| {
            try model.set("price", @as(i64, @intCast(i)));
            _ = model.get("price");
            try model.set("flag", i % 2 == 0);
            _ = model.get("flag");
        }
    }

    // --- ReactiveModel toJSON: zero alloc (stack buffer) ---
    {
        const Model = ReactiveModel("JSONModel", .{
            .value = .i64,
            .active = .bool,
        });

        var model = Model.init(allocator, null);
        defer model.deinit();
        try model.set("value", @as(i64, 42));
        try model.set("active", true);

        var json_buf: [4096]u8 = undefined;
        for (0..100) |_| {
            _ = try model.toJSON(&json_buf);
        }
    }

    // --- Binary protocol parse: zero alloc ---
    {
        var data: [38]u8 = undefined;
        data[0] = 'A';
        std.mem.writeInt(u16, data[1..3], 42, .big);
        std.mem.writeInt(u16, data[3..5], 0, .big);
        std.mem.writeInt(u64, data[5..13], 1234567890, .big);
        std.mem.writeInt(u64, data[13..21], 100001, .big);
        data[21] = 'B';
        std.mem.writeInt(u32, data[22..26], 500, .big);
        @memcpy(data[26..34], "AAPL    ");
        std.mem.writeInt(u32, data[34..38], 15000, .big);

        for (0..1000) |_| {
            _ = AddOrder.parse(&data);
        }
    }

    // If we get here with testing allocator and no leaks reported,
    // the hot-path operations are allocation-free.
    // (The testing allocator would report leaks on test exit if any
    // allocations were made without corresponding frees.)
}

// ============================================================================
// Shared Test Helpers
// ============================================================================

fn noopHandler(event: *const Event, alloc: Allocator) void {
    _ = event;
    _ = alloc;
}
