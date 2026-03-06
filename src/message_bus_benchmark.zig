/// Message Bus Load Test & Benchmark
/// Stress tests the message bus under high load
///
/// Usage:
///   ./zig-out/bin/message_bus_benchmark [options]
///
/// Options:
///   --events N        Number of events to publish (default: 100000)
///   --workers N       Number of EventWorker threads (default: 4)
///   --subscribers N   Number of subscribers (default: 10)
///   --duration N      Duration in seconds (default: 10)
///   --mode MODE       Test mode: latency, throughput, stress (default: latency)

const std = @import("std");
const Allocator = std.mem.Allocator;
const message_bus = @import("message_bus/mod.zig");
const Event = @import("event.zig").Event;

const BenchmarkConfig = struct {
    event_count: usize = 100_000,
    worker_count: usize = 4,
    subscriber_count: usize = 10,
    duration_seconds: u64 = 10,
    mode: TestMode = .latency,

    const TestMode = enum {
        latency,    // Measure publish latency
        throughput, // Measure max throughput
        stress,     // Stress test with high concurrency
    };
};

const Stats = struct {
    total_published: u64 = 0,
    total_delivered: u64 = 0,
    total_dropped: u64 = 0,
    publish_latencies_ns: std.ArrayList(u64),
    delivery_latencies_ns: std.ArrayList(u64),
    start_time: i64 = 0,
    end_time: i64 = 0,

    allocator: Allocator,

    pub fn init(allocator: Allocator) Stats {
        return .{
            .allocator = allocator,
            .publish_latencies_ns = .{},
            .delivery_latencies_ns = .{},
        };
    }

    pub fn deinit(self: *Stats) void {
        self.publish_latencies_ns.deinit(self.allocator);
        self.delivery_latencies_ns.deinit(self.allocator);
    }

    pub fn recordPublish(self: *Stats, latency_ns: u64) !void {
        try self.publish_latencies_ns.append(self.allocator, latency_ns);
        self.total_published += 1;
    }

    pub fn recordDelivery(self: *Stats, latency_ns: u64) !void {
        try self.delivery_latencies_ns.append(self.allocator, latency_ns);
        self.total_delivered += 1;
    }

    pub fn print(self: *Stats) void {
        const duration_s = @as(f64, @floatFromInt(self.end_time - self.start_time)) / 1_000_000.0;

        std.debug.print("\n", .{});
        std.debug.print("=" ** 60 ++ "\n", .{});
        std.debug.print("  Message Bus Benchmark Results\n", .{});
        std.debug.print("=" ** 60 ++ "\n", .{});
        std.debug.print("\n", .{});

        // Throughput
        std.debug.print("Throughput:\n", .{});
        std.debug.print("  Published:  {} events in {d:.2}s = {d:.0} events/sec\n", .{
            self.total_published,
            duration_s,
            @as(f64, @floatFromInt(self.total_published)) / duration_s,
        });
        std.debug.print("  Delivered:  {} events = {d:.0} events/sec\n", .{
            self.total_delivered,
            @as(f64, @floatFromInt(self.total_delivered)) / duration_s,
        });
        std.debug.print("  Dropped:    {} events\n", .{self.total_dropped});
        std.debug.print("\n", .{});

        // Publish latency
        if (self.publish_latencies_ns.items.len > 0) {
            std.debug.print("Publish Latency (µs):\n", .{});
            self.printLatencyStats(self.publish_latencies_ns.items);
            std.debug.print("\n", .{});
        }

        // Delivery latency
        if (self.delivery_latencies_ns.items.len > 0) {
            std.debug.print("Delivery Latency (µs):\n", .{});
            self.printLatencyStats(self.delivery_latencies_ns.items);
            std.debug.print("\n", .{});
        }

        std.debug.print("=" ** 60 ++ "\n", .{});
    }

    fn printLatencyStats(self: *Stats, latencies_ns: []u64) void {
        _ = self;
        if (latencies_ns.len == 0) return;

        // Sort for percentiles
        std.mem.sort(u64, latencies_ns, {}, std.sort.asc(u64));

        const p50 = latencies_ns[latencies_ns.len * 50 / 100];
        const p90 = latencies_ns[latencies_ns.len * 90 / 100];
        const p99 = latencies_ns[latencies_ns.len * 99 / 100];
        const p999 = latencies_ns[latencies_ns.len * 999 / 1000];
        const max = latencies_ns[latencies_ns.len - 1];

        // Calculate mean
        var sum: u128 = 0;
        for (latencies_ns) |lat| {
            sum += lat;
        }
        const mean = @divTrunc(sum, latencies_ns.len);

        std.debug.print("  Mean:  {d:.2} µs\n", .{@as(f64, @floatFromInt(mean)) / 1000.0});
        std.debug.print("  P50:   {d:.2} µs\n", .{@as(f64, @floatFromInt(p50)) / 1000.0});
        std.debug.print("  P90:   {d:.2} µs\n", .{@as(f64, @floatFromInt(p90)) / 1000.0});
        std.debug.print("  P99:   {d:.2} µs\n", .{@as(f64, @floatFromInt(p99)) / 1000.0});
        std.debug.print("  P99.9: {d:.2} µs\n", .{@as(f64, @floatFromInt(p999)) / 1000.0});
        std.debug.print("  Max:   {d:.2} µs\n", .{@as(f64, @floatFromInt(max)) / 1000.0});
    }
};

// Global stats (accessed by subscribers)
var global_stats: Stats = undefined;
var global_stats_mutex: std.Thread.Mutex = .{};

/// Subscriber that tracks delivery latency
fn benchmarkSubscriber(event: *const Event, allocator: Allocator) void {
    _ = allocator;

    // Calculate delivery latency (event timestamp to now)
    const now = std.time.microTimestamp();
    const latency_us = now - event.timestamp;
    const latency_ns = @as(u64, @intCast(latency_us * 1000));

    global_stats_mutex.lock();
    defer global_stats_mutex.unlock();

    global_stats.recordDelivery(latency_ns) catch {};
}

/// Latency test: Measure publish and delivery latency
fn testLatency(allocator: Allocator, config: BenchmarkConfig) !void {
    std.debug.print("\n=== Latency Test ===\n", .{});
    std.debug.print("Publishing {} events with {} workers and {} subscribers\n\n", .{
        config.event_count,
        config.worker_count,
        config.subscriber_count,
    });

    // Initialize message bus
    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 8192,
        .worker_count = config.worker_count,
        .flush_interval_ms = 10,
    });
    defer bus.deinit();

    try bus.start();

    // Subscribe multiple handlers
    const filter = message_bus.Filter{ .conditions = &.{} };
    const subscriptions = try allocator.alloc(message_bus.SubscriptionId, config.subscriber_count);
    defer allocator.free(subscriptions);

    for (subscriptions) |*sub| {
        sub.* = try bus.subscribe(
            message_bus.ModelTopics("Item").created,
            filter,
            benchmarkSubscriber,
        );
    }

    // Publish events and measure latency
    global_stats.start_time = std.time.microTimestamp();

    var i: usize = 0;
    while (i < config.event_count) : (i += 1) {
        // Create event
        var data_buffer: [256]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buffer,
            "{{\"id\":{d},\"name\":\"item_{d}\",\"value\":{d}}}",
            .{i, i, i * 100}
        );

        const event = Event{
            .id = @intCast(i),
            .timestamp = std.time.microTimestamp(),
            .event_type = .model_created,
            .topic = message_bus.ModelTopics("Item").created,
            .model_type = "Item",
            .model_id = i,
            .data = data,
        };

        // Measure publish latency
        const start = std.time.nanoTimestamp();
        bus.publish(event);
        const latency_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start));

        try global_stats.recordPublish(latency_ns);

        // Small delay to prevent queue overflow
        if (i % 1000 == 0) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    // Wait for delivery to complete
    std.debug.print("Waiting for event delivery...\n", .{});
    std.Thread.sleep(2000 * std.time.ns_per_ms);

    global_stats.end_time = std.time.microTimestamp();

    // Get bus stats
    const bus_stats = bus.getStats();
    global_stats.total_dropped = bus_stats.dropped;

    // Unsubscribe
    for (subscriptions) |sub| {
        bus.unsubscribe(sub);
    }

    // Print results
    global_stats.print();
}

/// Throughput test: Measure maximum throughput
fn testThroughput(allocator: Allocator, config: BenchmarkConfig) !void {
    std.debug.print("\n=== Throughput Test ===\n", .{});
    std.debug.print("Running for {} seconds with {} workers\n\n", .{
        config.duration_seconds,
        config.worker_count,
    });

    // Initialize message bus with larger queue
    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 16384, // Larger queue for throughput test
        .worker_count = config.worker_count,
        .flush_interval_ms = 1, // Aggressive polling
    });
    defer bus.deinit();

    try bus.start();

    // Single subscriber (minimal overhead)
    const filter = message_bus.Filter{ .conditions = &.{} };
    const sub_id = try bus.subscribe(
        message_bus.ModelTopics("Item").created,
        filter,
        benchmarkSubscriber,
    );

    global_stats.start_time = std.time.microTimestamp();
    const end_time = global_stats.start_time + @as(i64, @intCast(config.duration_seconds * 1_000_000));

    // Publish as fast as possible
    var event_id: usize = 0;
    while (std.time.microTimestamp() < end_time) {
        var data_buffer: [128]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buffer,
            "{{\"id\":{d}}}",
            .{event_id}
        );

        const event = Event{
            .id = @intCast(event_id),
            .timestamp = std.time.microTimestamp(),
            .event_type = .model_created,
            .topic = message_bus.ModelTopics("Item").created,
            .model_type = "Item",
            .model_id = event_id,
            .data = data,
        };

        bus.publish(event);
        event_id += 1;

        // Check for queue overflow
        if (event_id % 10000 == 0) {
            std.Thread.sleep(100); // Tiny delay to prevent overflow
        }
    }

    global_stats.end_time = std.time.microTimestamp();

    // Wait for delivery
    std.debug.print("Waiting for delivery...\n", .{});
    std.Thread.sleep(1000 * std.time.ns_per_ms);

    // Get stats
    const bus_stats = bus.getStats();
    global_stats.total_published = bus_stats.published;
    global_stats.total_dropped = bus_stats.dropped;

    bus.unsubscribe(sub_id);

    // Print results
    global_stats.print();
}

/// Stress test: High concurrency with many subscribers
fn testStress(allocator: Allocator, config: BenchmarkConfig) !void {
    std.debug.print("\n=== Stress Test ===\n", .{});
    std.debug.print("Running for {} seconds with {} workers and {} subscribers\n\n", .{
        config.duration_seconds,
        config.worker_count,
        config.subscriber_count,
    });

    // Initialize message bus
    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 16384,
        .worker_count = config.worker_count,
        .flush_interval_ms = 5,
    });
    defer bus.deinit();

    try bus.start();

    // Subscribe many handlers to different topics
    const filter = message_bus.Filter{ .conditions = &.{} };
    const subscriptions = try allocator.alloc(message_bus.SubscriptionId, config.subscriber_count);
    defer allocator.free(subscriptions);

    const topics = [_][]const u8{
        message_bus.ModelTopics("Item").created,
        message_bus.ModelTopics("Item").updated,
        message_bus.ModelTopics("Item").deleted,
        message_bus.ModelTopics("Order").created,
        message_bus.CustomTopic("Order.completed"),
    };

    for (subscriptions, 0..) |*sub, i| {
        const topic = topics[i % topics.len];
        sub.* = try bus.subscribe(topic, filter, benchmarkSubscriber);
    }

    global_stats.start_time = std.time.microTimestamp();
    const end_time = global_stats.start_time + @as(i64, @intCast(config.duration_seconds * 1_000_000));

    // Publish to different topics
    var event_id: usize = 0;
    while (std.time.microTimestamp() < end_time) {
        const topic = topics[event_id % topics.len];

        var data_buffer: [256]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buffer,
            "{{\"id\":{d},\"topic\":\"{s}\"}}",
            .{event_id, topic}
        );

        const event = Event{
            .id = @intCast(event_id),
            .timestamp = std.time.microTimestamp(),
            .event_type = .model_created,
            .topic = topic,
            .model_type = "Test",
            .model_id = event_id,
            .data = data,
        };

        bus.publish(event);
        event_id += 1;

        if (event_id % 5000 == 0) {
            std.Thread.sleep(100);
        }
    }

    global_stats.end_time = std.time.microTimestamp();

    // Wait for delivery
    std.debug.print("Waiting for delivery...\n", .{});
    std.Thread.sleep(2000 * std.time.ns_per_ms);

    // Get stats
    const bus_stats = bus.getStats();
    global_stats.total_published = bus_stats.published;
    global_stats.total_dropped = bus_stats.dropped;

    // Unsubscribe
    for (subscriptions) |sub| {
        bus.unsubscribe(sub);
    }

    // Print results
    global_stats.print();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    var config = BenchmarkConfig{};

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // Skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--events")) {
            const val = args.next() orelse {
                std.debug.print("Error: --events requires a value\n", .{});
                return error.InvalidArgument;
            };
            config.event_count = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "--workers")) {
            const val = args.next() orelse {
                std.debug.print("Error: --workers requires a value\n", .{});
                return error.InvalidArgument;
            };
            config.worker_count = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "--subscribers")) {
            const val = args.next() orelse {
                std.debug.print("Error: --subscribers requires a value\n", .{});
                return error.InvalidArgument;
            };
            config.subscriber_count = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "--duration")) {
            const val = args.next() orelse {
                std.debug.print("Error: --duration requires a value\n", .{});
                return error.InvalidArgument;
            };
            config.duration_seconds = try std.fmt.parseInt(u64, val, 10);
        } else if (std.mem.eql(u8, arg, "--mode")) {
            const val = args.next() orelse {
                std.debug.print("Error: --mode requires a value\n", .{});
                return error.InvalidArgument;
            };
            if (std.mem.eql(u8, val, "latency")) {
                config.mode = .latency;
            } else if (std.mem.eql(u8, val, "throughput")) {
                config.mode = .throughput;
            } else if (std.mem.eql(u8, val, "stress")) {
                config.mode = .stress;
            } else {
                std.debug.print("Error: Invalid mode '{s}'. Use: latency, throughput, stress\n", .{val});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else {
            std.debug.print("Error: Unknown argument '{s}'\n", .{arg});
            printHelp();
            return error.InvalidArgument;
        }
    }

    // Initialize global stats
    global_stats = Stats.init(allocator);
    defer global_stats.deinit();

    // Run test based on mode
    switch (config.mode) {
        .latency => try testLatency(allocator, config),
        .throughput => try testThroughput(allocator, config),
        .stress => try testStress(allocator, config),
    }
}

fn printHelp() void {
    std.debug.print(
        \\Message Bus Benchmark Tool
        \\
        \\Usage: message_bus_benchmark [options]
        \\
        \\Options:
        \\  --events N        Number of events to publish (default: 100000)
        \\  --workers N       Number of EventWorker threads (default: 4)
        \\  --subscribers N   Number of subscribers (default: 10)
        \\  --duration N      Duration in seconds for timed tests (default: 10)
        \\  --mode MODE       Test mode: latency, throughput, stress (default: latency)
        \\  --help            Show this help message
        \\
        \\Test Modes:
        \\  latency      Measure publish and delivery latency (P50, P99, etc.)
        \\  throughput   Measure maximum events/sec sustained throughput
        \\  stress       Stress test with many subscribers and topics
        \\
        \\Examples:
        \\  ./message_bus_benchmark --mode latency --events 50000
        \\  ./message_bus_benchmark --mode throughput --duration 30 --workers 8
        \\  ./message_bus_benchmark --mode stress --subscribers 100 --duration 60
        \\
    , .{});
}
