const std = @import("std");
const Allocator = std.mem.Allocator;
const Event = @import("../event.zig").Event;

/// MPMC-safe ring buffer using per-slot sequence numbers (Vyukov pattern).
///
/// Each slot carries a sequence number that coordinates producers and consumers:
///   - Producer: CAS head to claim index, write event, publish via sequence store
///   - Consumer: CAS tail to claim index, spin until sequence is ready, read event
///
/// This eliminates the torn-read race where a consumer observes an advanced head
/// but reads a slot before the producer finishes writing.
pub const EventRingBuffer = struct {
    const Self = @This();

    const Slot = struct {
        event: Event,
        sequence: std.atomic.Value(usize),
    };

    capacity: usize,
    mask: usize,
    slots: []Slot,
    // Cache line padding: head and tail are contended by different threads
    // (producers vs consumers). Without padding, they share a cache line
    // causing false sharing and cross-core invalidation traffic.
    head: std.atomic.Value(usize) align(64), // Producer claim position
    _pad: [64 - @sizeOf(std.atomic.Value(usize))]u8 = undefined,
    tail: std.atomic.Value(usize) align(64), // Consumer claim position
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) !Self {
        // Round up to power of 2 for mask-based indexing
        const actual_capacity = blk: {
            if (capacity == 0) break :blk 1;
            var n = capacity - 1;
            n |= n >> 1;
            n |= n >> 2;
            n |= n >> 4;
            n |= n >> 8;
            n |= n >> 16;
            if (@sizeOf(usize) > 4) n |= n >> 32;
            break :blk n + 1;
        };

        const slots = try allocator.alloc(Slot, actual_capacity);
        for (slots, 0..) |*slot, i| {
            slot.sequence = std.atomic.Value(usize).init(i);
            slot.event = undefined;
        }

        return Self{
            .capacity = actual_capacity,
            .mask = actual_capacity - 1,
            .slots = slots,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.slots);
    }

    /// Non-blocking push (returns false if full).
    /// Thread-safe for multiple concurrent producers.
    pub fn push(self: *Self, event: Event) bool {
        var head = self.head.load(.monotonic);
        while (true) {
            const slot = &self.slots[head & self.mask];
            const seq = slot.sequence.load(.acquire);
            const diff = @as(isize, @intCast(seq)) - @as(isize, @intCast(head));

            if (diff == 0) {
                // Slot is available for writing — try to claim it
                if (self.head.cmpxchgWeak(head, head + 1, .acq_rel, .monotonic)) |updated| {
                    head = updated;
                    continue;
                }
                // Claimed. Write the event, then publish by advancing the sequence.
                slot.event = event;
                slot.sequence.store(head + 1, .release);
                return true;
            } else if (diff < 0) {
                // Slot still occupied by a consumer — buffer is full
                return false;
            } else {
                // Another producer claimed this slot — reload head and retry
                head = self.head.load(.monotonic);
            }
        }
    }

    /// Non-blocking pop (returns null if empty).
    /// Thread-safe for multiple concurrent consumers.
    pub fn pop(self: *Self) ?Event {
        var tail = self.tail.load(.monotonic);
        while (true) {
            const slot = &self.slots[tail & self.mask];
            const seq = slot.sequence.load(.acquire);
            const diff = @as(isize, @intCast(seq)) - @as(isize, @intCast(tail + 1));

            if (diff == 0) {
                // Slot is ready for reading — try to claim it
                if (self.tail.cmpxchgWeak(tail, tail + 1, .acq_rel, .monotonic)) |updated| {
                    tail = updated;
                    continue;
                }
                // Claimed. Read the event, then release the slot for producers.
                const event = slot.event;
                slot.sequence.store(tail + self.capacity, .release);
                return event;
            } else if (diff < 0) {
                // No data available — buffer is empty
                return null;
            } else {
                // Another consumer claimed this slot — reload tail and retry
                tail = self.tail.load(.monotonic);
            }
        }
    }

    /// Approximate size. NOT linearizable — head and tail are read non-atomically
    /// as a pair, so the result may be stale or briefly negative under concurrency.
    /// Safe for diagnostics/stats, NOT for control flow decisions.
    pub fn size(self: *const Self) usize {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        return head -| tail;
    }

    /// Approximate emptiness check. See size() for concurrency caveat.
    pub fn isEmpty(self: *const Self) bool {
        return self.size() == 0;
    }

    /// Approximate fullness check. See size() for concurrency caveat.
    pub fn isFull(self: *const Self) bool {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        return (head - tail) >= self.capacity;
    }
};

test "ring buffer push and pop" {
    const allocator = std.testing.allocator;

    var buffer = try EventRingBuffer.init(allocator, 4);
    defer buffer.deinit();

    const event1 = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{}",
    };

    const event2 = Event{
        .id = 2,
        .timestamp = 200,
        .event_type = .model_updated,
        .topic = "Test.updated",
        .model_type = "Test",
        .model_id = 2,
        .data = "{}",
    };

    // Push events
    try std.testing.expect(buffer.push(event1));
    try std.testing.expect(buffer.push(event2));
    try std.testing.expectEqual(@as(usize, 2), buffer.size());

    // Pop events
    const popped1 = buffer.pop().?;
    try std.testing.expectEqual(@as(u128, 1), popped1.id);

    const popped2 = buffer.pop().?;
    try std.testing.expectEqual(@as(u128, 2), popped2.id);

    // Buffer should be empty
    try std.testing.expect(buffer.pop() == null);
}

test "ring buffer full" {
    const allocator = std.testing.allocator;

    var buffer = try EventRingBuffer.init(allocator, 4);
    defer buffer.deinit();

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{}",
    };

    // Fill buffer (all 4 slots in power-of-2 ring buffer)
    try std.testing.expect(buffer.push(event));
    try std.testing.expect(buffer.push(event));
    try std.testing.expect(buffer.push(event));
    try std.testing.expect(buffer.push(event));

    // Next push should fail (buffer full)
    try std.testing.expect(!buffer.push(event));
}

test "ring buffer wrap around" {
    const allocator = std.testing.allocator;

    var buffer = try EventRingBuffer.init(allocator, 4);
    defer buffer.deinit();

    // Fill and drain multiple times to test wrap-around
    for (0..3) |round| {
        for (0..4) |i| {
            const event = Event{
                .id = @intCast(round * 4 + i),
                .timestamp = @intCast(round * 4 + i),
                .event_type = .model_created,
                .topic = "Test.created",
                .model_type = "Test",
                .model_id = @intCast(round * 4 + i),
                .data = "{}",
            };
            try std.testing.expect(buffer.push(event));
        }

        for (0..4) |i| {
            const popped = buffer.pop().?;
            try std.testing.expectEqual(@as(u128, @intCast(round * 4 + i)), popped.id);
        }

        try std.testing.expect(buffer.pop() == null);
    }
}

test "ring buffer MPMC correctness - no torn reads" {
    const allocator = std.testing.allocator;

    var buffer = try EventRingBuffer.init(allocator, 256);
    defer buffer.deinit();

    const num_producers = 4;
    const num_consumers = 4;
    const events_per_producer = 10_000;

    var shutdown = std.atomic.Value(bool).init(false);
    var total_produced = std.atomic.Value(u64).init(0);
    var total_consumed = std.atomic.Value(u64).init(0);
    var torn_reads = std.atomic.Value(u64).init(0);

    const ProducerCtx = struct {
        buffer: *EventRingBuffer,
        producer_id: usize,
        total_produced: *std.atomic.Value(u64),
    };

    const ConsumerCtx = struct {
        buffer: *EventRingBuffer,
        shutdown: *std.atomic.Value(bool),
        total_consumed: *std.atomic.Value(u64),
        torn_reads: *std.atomic.Value(u64),
        expected_total: u64,
    };

    const producer_fn = struct {
        fn run(ctx: ProducerCtx) void {
            for (0..events_per_producer) |i| {
                const seq: u64 = ctx.producer_id * events_per_producer + i;
                const event = Event{
                    .id = seq,
                    .timestamp = @intCast(seq),
                    .event_type = .model_created,
                    .topic = "test",
                    .model_type = "test",
                    .model_id = seq,
                    .data = "{}",
                };
                while (!ctx.buffer.push(event)) {
                    std.atomic.spinLoopHint();
                }
                _ = ctx.total_produced.fetchAdd(1, .monotonic);
            }
        }
    }.run;

    const consumer_fn = struct {
        fn run(ctx: ConsumerCtx) void {
            while (true) {
                const consumed = ctx.total_consumed.load(.monotonic);
                if (consumed >= ctx.expected_total and ctx.shutdown.load(.acquire)) break;

                const event = ctx.buffer.pop() orelse {
                    if (ctx.shutdown.load(.acquire) and ctx.total_consumed.load(.monotonic) >= ctx.expected_total) break;
                    std.atomic.spinLoopHint();
                    continue;
                };

                // A torn read will have mismatched id vs model_id
                if (event.id != event.model_id) {
                    _ = ctx.torn_reads.fetchAdd(1, .monotonic);
                }
                if (event.timestamp != @as(i64, @intCast(event.model_id))) {
                    _ = ctx.torn_reads.fetchAdd(1, .monotonic);
                }

                _ = ctx.total_consumed.fetchAdd(1, .monotonic);
            }
        }
    }.run;

    const expected_total: u64 = num_producers * events_per_producer;

    var consumer_threads: [num_consumers]std.Thread = undefined;
    var consumer_ctxs: [num_consumers]ConsumerCtx = undefined;
    for (0..num_consumers) |i| {
        consumer_ctxs[i] = .{
            .buffer = &buffer,
            .shutdown = &shutdown,
            .total_consumed = &total_consumed,
            .torn_reads = &torn_reads,
            .expected_total = expected_total,
        };
        consumer_threads[i] = try std.Thread.spawn(.{}, consumer_fn, .{consumer_ctxs[i]});
    }

    var producer_threads: [num_producers]std.Thread = undefined;
    var producer_ctxs: [num_producers]ProducerCtx = undefined;
    for (0..num_producers) |i| {
        producer_ctxs[i] = .{ .buffer = &buffer, .producer_id = i, .total_produced = &total_produced };
        producer_threads[i] = try std.Thread.spawn(.{}, producer_fn, .{producer_ctxs[i]});
    }

    for (producer_threads) |t| t.join();
    shutdown.store(true, .release);
    for (consumer_threads) |t| t.join();

    const torn = torn_reads.load(.monotonic);
    const consumed = total_consumed.load(.monotonic);

    // All events consumed with zero torn reads
    try std.testing.expectEqual(@as(u64, 0), torn);
    try std.testing.expectEqual(expected_total, consumed);
}
