const std = @import("std");
const Allocator = std.mem.Allocator;
const Event = @import("../event.zig").Event;
const EventRingBuffer = @import("ring_buffer.zig").EventRingBuffer;
const LockFreeSubscriberRegistry = @import("lockfree_subscriber_registry.zig").LockFreeSubscriberRegistry;
const Filter = @import("filter.zig").Filter;
const HandlerFn = @import("subscriber.zig").HandlerFn;
const SubscriptionId = @import("subscriber.zig").SubscriptionId;
const EventWorker = @import("event_worker.zig").EventWorker;

pub const MessageBus = struct {
    const Self = @This();

    event_queue: EventRingBuffer,
    subscribers: LockFreeSubscriberRegistry,
    workers: []EventWorker,
    worker_threads: []std.Thread,
    shutdown: std.atomic.Value(bool),
    started: bool,
    // Cache-line-aligned counters to avoid false sharing between
    // publisher threads (total_published/total_dropped) and worker
    // threads (total_delivered).
    total_published: std.atomic.Value(u64) align(64),
    total_dropped: std.atomic.Value(u64),
    total_delivered: std.atomic.Value(u64) align(64),
    config: Config,
    allocator: Allocator,

    pub const Config = struct {
        queue_capacity: usize = 8192,
        worker_count: usize = 4,
        batch_size: usize = 64,
        flush_interval_ms: u64 = 100,
    };

    pub fn init(allocator: Allocator, config: Config) !Self {
        return Self{
            .event_queue = try EventRingBuffer.init(allocator, config.queue_capacity),
            .subscribers = try LockFreeSubscriberRegistry.init(allocator),
            .workers = try allocator.alloc(EventWorker, config.worker_count),
            .worker_threads = try allocator.alloc(std.Thread, config.worker_count),
            .shutdown = std.atomic.Value(bool).init(false),
            .started = false,
            .total_published = std.atomic.Value(u64).init(0),
            .total_dropped = std.atomic.Value(u64).init(0),
            .total_delivered = std.atomic.Value(u64).init(0),
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

        if (self.started) {
            for (self.worker_threads) |thread| {
                thread.join();
            }
        }

        while (self.event_queue.pop()) |event| {
            event.deinit(self.allocator);
        }

        self.event_queue.deinit();
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

        self.started = true;
        std.log.info("MessageBus started with {} workers", .{self.workers.len});
    }

    /// Publish an event to the bus. Returns true on success, false if dropped (queue full).
    /// On drop, owned event data is freed automatically.
    pub fn publish(self: *Self, event: Event) bool {
        if (self.event_queue.push(event)) {
            _ = self.total_published.fetchAdd(1, .monotonic);
            return true;
        } else {
            // Free owned event data to prevent memory leak
            event.deinit(self.allocator);
            const dropped = self.total_dropped.fetchAdd(1, .monotonic);
            if (dropped % 1000 == 0) {
                std.log.warn("Event queue full - dropped {} total events", .{dropped + 1});
            }
            return false;
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
            .queued = self.event_queue.size(),
        };
    }

    pub const Stats = struct {
        published: u64,
        dropped: u64,
        delivered: u64,
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
