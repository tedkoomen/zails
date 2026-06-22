const std = @import("std");
const Allocator = std.mem.Allocator;
const Event = @import("../event.zig").Event;
const EventRingBuffer = @import("ring_buffer.zig").EventRingBuffer;
const PayloadPool = @import("payload_pool.zig").PayloadPool;
const LockFreeSubscriberRegistry = @import("lockfree_subscriber_registry.zig").LockFreeSubscriberRegistry;
const Filter = @import("filter.zig").Filter;
const HandlerFn = @import("subscriber.zig").HandlerFn;
const SubscriptionId = @import("subscriber.zig").SubscriptionId;
const EventWorker = @import("event_worker.zig").EventWorker;

pub const MessageBus = struct {
    const Self = @This();

    event_queue: EventRingBuffer,
    payload_pool: PayloadPool,
    subscribers: LockFreeSubscriberRegistry,
    workers: []EventWorker,
    worker_threads: []std.Thread,
    shutdown: std.atomic.Value(bool),
    started: std.atomic.Value(bool),
    // Cache-line-aligned counters to avoid false sharing between
    // publisher threads (total_published/total_dropped) and worker
    // threads (total_delivered).
    total_published: std.atomic.Value(u64) align(64),
    total_dropped: std.atomic.Value(u64) align(64),
    total_delivered: std.atomic.Value(u64) align(64),
    total_backpressure: std.atomic.Value(u64) align(64),
    config: Config,
    allocator: Allocator,

    pub const Config = struct {
        queue_capacity: usize = 8192,
        worker_count: usize = 4,
        batch_size: usize = 64,
        flush_interval_ms: u64 = 100,
        overflow_policy: OverflowPolicy = .drop_newest,
        spin_before_yield: usize = 256,
        yields_before_sleep: usize = 32,
        backpressure_sleep_ns: u64 = 50_000,
        max_backpressure_wait_ns: u64 = 5_000_000,
        drop_log_interval: u64 = 10_000,
        /// 0 means "match queue_capacity" so every queued borrowed event can have a slot.
        payload_pool_capacity: usize = 0,
        payload_pool_slot_size: usize = 4096,
    };

    pub const OverflowPolicy = enum {
        /// Preserve ultra-low publish latency by dropping the new event if the queue is full.
        drop_newest,
        /// Preserve events by applying producer backpressure until a queue slot opens.
        backpressure,
    };

    pub fn init(allocator: Allocator, config: Config) !Self {
        var event_queue = try EventRingBuffer.init(allocator, config.queue_capacity);
        errdefer event_queue.deinit();

        const pool_capacity = if (config.payload_pool_capacity == 0)
            config.queue_capacity
        else
            config.payload_pool_capacity;
        var payload_pool = try PayloadPool.init(allocator, pool_capacity, config.payload_pool_slot_size);
        errdefer payload_pool.deinit();

        var subscribers = try LockFreeSubscriberRegistry.init(allocator);
        errdefer subscribers.deinit();

        const workers = try allocator.alloc(EventWorker, config.worker_count);
        errdefer allocator.free(workers);

        const worker_threads = try allocator.alloc(std.Thread, config.worker_count);

        return Self{
            .event_queue = event_queue,
            .payload_pool = payload_pool,
            .subscribers = subscribers,
            .workers = workers,
            .worker_threads = worker_threads,
            .shutdown = std.atomic.Value(bool).init(false),
            .started = std.atomic.Value(bool).init(false),
            .total_published = std.atomic.Value(u64).init(0),
            .total_dropped = std.atomic.Value(u64).init(0),
            .total_delivered = std.atomic.Value(u64).init(0),
            .total_backpressure = std.atomic.Value(u64).init(0),
            .config = config,
            .allocator = allocator,
        };
    }

    /// Initialize workers after MessageBus is in final memory location
    fn initWorkers(self: *Self) void {
        for (self.workers, 0..) |*worker, i| {
            worker.* = EventWorker.init(i, self, self.config);
        }
    }

    pub fn deinit(self: *Self) void {
        self.shutdown.store(true, .release);

        if (self.started.load(.acquire)) {
            for (self.worker_threads) |thread| {
                thread.join();
            }
        }

        while (self.event_queue.pop()) |event| {
            event.deinit(self.allocator);
        }

        self.event_queue.deinit();
        self.payload_pool.deinit();
        self.subscribers.deinit();
        self.allocator.free(self.workers);
        self.allocator.free(self.worker_threads);
    }

    pub fn start(self: *Self) !void {
        self.initWorkers();

        var spawned: usize = 0;
        errdefer {
            // On failure, shut down and join already-spawned threads
            self.shutdown.store(true, .release);
            for (self.worker_threads[0..spawned]) |thread| {
                thread.join();
            }
        }

        for (self.workers, 0..) |*worker, i| {
            self.worker_threads[i] = try std.Thread.spawn(.{}, EventWorker.run, .{worker});
            spawned += 1;
        }

        self.started.store(true, .release);
        std.log.info("MessageBus started with {} workers", .{self.workers.len});
    }

    /// Publish an event to the bus. Returns true on success, false if dropped (queue full).
    /// On drop, owned event data is freed automatically.
    pub fn publish(self: *Self, event: Event) bool {
        if (self.shutdown.load(.acquire)) {
            self.dropEvent(event);
            return false;
        }

        const queued_event = self.prepareEventForQueue(event) orelse {
            self.dropEvent(event);
            return false;
        };

        return self.enqueuePreparedEvent(queued_event);
    }

    /// Publish without copying borrowed slices into the payload pool.
    /// Use only when every borrowed slice has a lifetime that outlives async delivery.
    pub fn publishBorrowedUnsafe(self: *Self, event: Event) bool {
        if (self.shutdown.load(.acquire)) {
            self.dropEvent(event);
            return false;
        }

        return self.enqueuePreparedEvent(event);
    }

    fn enqueuePreparedEvent(self: *Self, event: Event) bool {
        if (self.event_queue.push(event)) {
            _ = self.total_published.fetchAdd(1, .monotonic);
            return true;
        }

        switch (self.config.overflow_policy) {
            .drop_newest => {
                self.dropEvent(event);
                return false;
            },
            .backpressure => return self.publishWithBackpressure(event),
        }
    }

    fn prepareEventForQueue(self: *Self, event: Event) ?Event {
        return switch (event.payload_owner) {
            .borrowed => self.copyBorrowedEventToPool(event),
            .heap, .pooled => event,
        };
    }

    fn copyBorrowedEventToPool(self: *Self, event: Event) ?Event {
        const total_len = event.topic.len + event.model_type.len + event.data.len;
        const reservation = self.payload_pool.reserve(total_len) orelse return null;

        var pos: usize = 0;
        var queued = event;
        queued.topic = copyIntoReservation(reservation.bytes, &pos, event.topic);
        queued.model_type = copyIntoReservation(reservation.bytes, &pos, event.model_type);
        queued.data = copyIntoReservation(reservation.bytes, &pos, event.data);
        queued.owned = false;
        queued.payload_owner = .{ .pooled = reservation.handle };
        return queued;
    }

    fn copyIntoReservation(storage: []u8, pos: *usize, bytes: []const u8) []const u8 {
        const offset = pos.*;
        const end = offset + bytes.len;
        @memcpy(storage[offset..end], bytes);
        pos.* = end;
        return storage[offset..end];
    }

    fn publishWithBackpressure(self: *Self, event: Event) bool {
        if (!self.started.load(.acquire)) {
            self.dropEvent(event);
            return false;
        }

        _ = self.total_backpressure.fetchAdd(1, .monotonic);

        const wait_started_ns = std.time.nanoTimestamp();
        var spins: usize = 0;
        var yields: usize = 0;
        while (!self.shutdown.load(.acquire)) {
            if (self.event_queue.push(event)) {
                _ = self.total_published.fetchAdd(1, .monotonic);
                return true;
            }

            if (self.config.max_backpressure_wait_ns > 0) {
                const elapsed_ns = std.time.nanoTimestamp() - wait_started_ns;
                if (elapsed_ns >= @as(i128, @intCast(self.config.max_backpressure_wait_ns))) {
                    self.dropEvent(event);
                    return false;
                }
            }

            if (spins < self.config.spin_before_yield) {
                spins += 1;
                std.atomic.spinLoopHint();
                continue;
            }

            if (yields < self.config.yields_before_sleep) {
                yields += 1;
                std.Thread.yield() catch {};
                continue;
            }

            std.Thread.sleep(self.config.backpressure_sleep_ns);
        }

        self.dropEvent(event);
        return false;
    }

    fn dropEvent(self: *Self, event: Event) void {
        // Release heap or pool-backed event data to prevent memory leaks.
        event.deinit(self.allocator);
        const dropped = self.total_dropped.fetchAdd(1, .monotonic) + 1;
        if (dropped == 1 or dropped % self.config.drop_log_interval == 0) {
            std.log.warn("Event queue full - dropped {} total events", .{dropped});
        }
    }

    pub fn subscribe(
        self: *Self,
        topic: []const u8,
        filter: Filter,
        handler: HandlerFn,
    ) !SubscriptionId {
        return try self.subscribers.subscribe(topic, filter, handler);
    }

    pub fn unsubscribe(self: *Self, id: SubscriptionId) void {
        self.subscribers.unsubscribe(id);
    }

    pub fn getStats(self: *const Self) Stats {
        return Stats{
            .published = self.total_published.load(.acquire),
            .dropped = self.total_dropped.load(.acquire),
            .delivered = self.total_delivered.load(.acquire),
            .backpressure = self.total_backpressure.load(.acquire),
            .queued = self.event_queue.size(),
        };
    }

    pub const Stats = struct {
        published: u64,
        dropped: u64,
        delivered: u64,
        backpressure: u64,
        queued: usize,
    };
};

// Test helper
fn testHandler(event: *const Event, allocator: Allocator) void {
    _ = event;
    _ = allocator;
}

test "message bus init and deinit" {
    const allocator = std.testing.allocator;

    var bus = try MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 2,
    });
    defer bus.deinit();

    try std.testing.expect(bus.workers.len == 2);
}

test "message bus publish and subscribe" {
    const allocator = std.testing.allocator;

    var bus = try MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1,
    });
    defer bus.deinit();

    const filter = Filter{ .conditions = &.{} };
    const sub_id = try bus.subscribe("Test.created", filter, testHandler);

    // Use owned event for proper memory management
    const event = try Event.initOwned(
        allocator,
        .model_created,
        "Test.created",
        "Test",
        1,
        "{}",
    );

    _ = bus.publish(event);

    const stats = bus.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.published);
    try std.testing.expectEqual(@as(u64, 0), stats.dropped);

    bus.unsubscribe(sub_id);
}

test "message bus queue overflow" {
    const allocator = std.testing.allocator;

    var bus = try MessageBus.init(allocator, .{
        .queue_capacity = 4, // Small queue (4 slots with Vyukov MPMC)
        .worker_count = 1,
        .overflow_policy = .drop_newest,
    });
    defer bus.deinit();

    // Use owned events — fill all 4 slots
    const event1 = try Event.initOwned(allocator, .model_created, "Test.created", "Test", 1, "{}");
    const event2 = try Event.initOwned(allocator, .model_created, "Test.created", "Test", 2, "{}");
    const event3 = try Event.initOwned(allocator, .model_created, "Test.created", "Test", 3, "{}");
    const event4 = try Event.initOwned(allocator, .model_created, "Test.created", "Test", 4, "{}");
    const event5 = try Event.initOwned(allocator, .model_created, "Test.created", "Test", 5, "{}");

    _ = bus.publish(event1);
    _ = bus.publish(event2);
    _ = bus.publish(event3);
    _ = bus.publish(event4);

    const stats1 = bus.getStats();
    try std.testing.expectEqual(@as(u64, 4), stats1.published);

    // 5th event should be dropped (queue full)
    _ = bus.publish(event5);

    const stats2 = bus.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats2.dropped);

    // event5 is automatically freed by publish() when dropped
}

test "message bus copies borrowed payload into pool before enqueue" {
    const allocator = std.testing.allocator;

    var bus = try MessageBus.init(allocator, .{
        .queue_capacity = 4,
        .worker_count = 1,
        .payload_pool_slot_size = 128,
    });
    defer bus.deinit();

    var data_buffer: [64]u8 = undefined;
    const data = try std.fmt.bufPrint(&data_buffer, "{{\"value\":{d}}}", .{42});

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .custom,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = data,
    };

    try std.testing.expect(bus.publish(event));
    @memset(data_buffer[0..data.len], 'x');

    const queued = bus.event_queue.pop() orelse return error.ExpectedQueuedEvent;
    defer queued.deinit(allocator);

    try std.testing.expectEqualStrings("{\"value\":42}", queued.data);
    switch (queued.payload_owner) {
        .pooled => {},
        else => return error.ExpectedPooledPayload,
    }
}

test "message bus rejects publish after shutdown" {
    const allocator = std.testing.allocator;

    var bus = try MessageBus.init(allocator, .{
        .queue_capacity = 4,
        .worker_count = 1,
    });
    defer bus.deinit();

    bus.shutdown.store(true, .release);

    const event = try Event.initOwned(allocator, .custom, "Test.created", "Test", 1, "{}");
    try std.testing.expect(!bus.publish(event));

    const stats = bus.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.published);
    try std.testing.expectEqual(@as(u64, 1), stats.dropped);
}
