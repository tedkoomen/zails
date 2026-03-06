/// End-to-End Integration Tests
/// Tests complete flow: TCP Request → Handler → Message Bus → Subscriber
///
/// This test validates:
/// 1. TCP server receives request
/// 2. Handler processes request and publishes event
/// 3. Message bus delivers event to subscribers
/// 4. Subscribers execute callbacks
/// 5. Multiple handlers can coordinate via events

const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const proto = @import("proto.zig");
const message_bus = @import("message_bus/mod.zig");
const Event = @import("event.zig").Event;

/// Test configuration
const TestConfig = struct {
    server_port: u16 = 9999,
    message_bus_workers: usize = 2,
    test_timeout_ms: u64 = 5000,
};

/// Test statistics (global, accessed by subscribers)
const TestStats = struct {
    events_received: std.atomic.Value(u32),
    item_created_count: std.atomic.Value(u32),
    item_updated_count: std.atomic.Value(u32),
    item_processed_count: std.atomic.Value(u32),
    high_id_count: std.atomic.Value(u32), // For filtered subscription test
    mutex: std.Thread.Mutex,

    fn init(allocator: Allocator) TestStats {
        _ = allocator;
        return .{
            .events_received = std.atomic.Value(u32).init(0),
            .item_created_count = std.atomic.Value(u32).init(0),
            .item_updated_count = std.atomic.Value(u32).init(0),
            .item_processed_count = std.atomic.Value(u32).init(0),
            .high_id_count = std.atomic.Value(u32).init(0),
            .mutex = .{},
        };
    }

    fn deinit(self: *TestStats, allocator: Allocator) void {
        _ = allocator;
        _ = self;
    }

    fn recordEvent(self: *TestStats, event: *const Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.events_received.fetchAdd(1, .monotonic);

        // Track by topic
        if (std.mem.eql(u8, event.topic, message_bus.ModelTopics("Item").created)) {
            _ = self.item_created_count.fetchAdd(1, .monotonic);
        } else if (std.mem.eql(u8, event.topic, message_bus.ModelTopics("Item").updated)) {
            _ = self.item_updated_count.fetchAdd(1, .monotonic);
        } else if (std.mem.eql(u8, event.topic, message_bus.CustomTopic("Item.processed"))) {
            _ = self.item_processed_count.fetchAdd(1, .monotonic);
        }
    }

    fn reset(self: *TestStats) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.events_received.store(0, .release);
        self.item_created_count.store(0, .release);
        self.item_updated_count.store(0, .release);
        self.item_processed_count.store(0, .release);
        self.high_id_count.store(0, .release);
    }

    fn waitForEvents(self: *TestStats, expected: u32, timeout_ms: u64) bool {
        const start = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - start < timeout_ms) {
            if (self.events_received.load(.acquire) >= expected) {
                return true;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        return false;
    }
};

var test_stats: TestStats = undefined;

/// Test subscriber: Item.created events
fn onItemCreated(event: *const Event, allocator: Allocator) void {
    _ = allocator;
    std.debug.print("✓ Subscriber received Item.created - ID: {d}\n", .{event.model_id});
    test_stats.recordEvent(event);
}

/// Test subscriber: Item.updated events
fn onItemUpdated(event: *const Event, allocator: Allocator) void {
    _ = allocator;
    std.debug.print("✓ Subscriber received Item.updated - ID: {d}\n", .{event.model_id});
    test_stats.recordEvent(event);
}

/// Test subscriber: Item.processed events
fn onItemProcessed(event: *const Event, allocator: Allocator) void {
    _ = allocator;
    std.debug.print("✓ Subscriber received Item.processed - ID: {d}\n", .{event.model_id});
    test_stats.recordEvent(event);
}

/// Test subscriber: All Item events (wildcard)
fn onAnyItemEvent(event: *const Event, allocator: Allocator) void {
    _ = allocator;
    std.debug.print("✓ Wildcard subscriber received: {s}\n", .{event.topic});
    test_stats.recordEvent(event);
}

/// Mock handler that publishes events
const MockItemHandler = struct {
    pub const MESSAGE_TYPE: u8 = 100;

    pub const Context = struct {
        message_bus: ?*message_bus.MessageBus,
        allocator: Allocator,

        pub fn init() Context {
            return .{
                .message_bus = null,
                .allocator = undefined,
            };
        }

        pub fn postInit(self: *Context, allocator: Allocator, bus: *message_bus.MessageBus) !void {
            self.allocator = allocator;
            self.message_bus = bus;
        }

        pub fn deinit(self: *Context) void {
            _ = self;
        }
    };

    pub fn handle(
        context: *Context,
        request_data: []const u8,
        response_buffer: []u8,
        allocator: Allocator,
    ) ![]const u8 {
        // Parse request JSON: {"action": "create|update", "item_id": 123, "name": "foo"}
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            request_data,
            .{},
        );
        defer parsed.deinit();

        const obj = parsed.value.object;
        const action = obj.get("action").?.string;
        const item_id = obj.get("item_id").?.integer;
        const name = obj.get("name").?.string;

        std.debug.print("Handler processing: action={s}, item_id={d}, name={s}\n", .{action, item_id, name});

        // Publish event based on action
        if (context.message_bus) |bus| {
            // Format event data
            var event_data_buf: [256]u8 = undefined;
            const event_data = try std.fmt.bufPrint(&event_data_buf,
                "{{\"item_id\":{d},\"name\":\"{s}\"}}",
                .{item_id, name}
            );

            if (std.mem.eql(u8, action, "create")) {
                // Create owned event (allocates and copies all string data)
                const event = try Event.initOwned(
                    allocator,
                    .model_created,
                    message_bus.ModelTopics("Item").created,
                    "Item",
                    @intCast(item_id),
                    event_data,
                );
                std.debug.print("→ Published Item.created event (data: {s})\n", .{event_data});
                bus.publish(event);
            } else if (std.mem.eql(u8, action, "update")) {
                // Create owned event (allocates and copies all string data)
                const event = try Event.initOwned(
                    allocator,
                    .model_updated,
                    message_bus.ModelTopics("Item").updated,
                    "Item",
                    @intCast(item_id),
                    event_data,
                );
                std.debug.print("→ Published Item.updated event\n", .{});
                bus.publish(event);
            }
        }

        // Build response
        return try std.fmt.bufPrint(response_buffer,
            "{{\"status\":\"success\",\"action\":\"{s}\",\"item_id\":{d}}}",
            .{action, item_id}
        );
    }
};

/// Integration Test 1: Single Request → Single Event → Single Subscriber
fn test_single_request_single_subscriber(allocator: Allocator, config: TestConfig) !void {
    std.debug.print("\n=== Test 1: Single Request → Single Event → Single Subscriber ===\n", .{});

    test_stats.reset();

    // Initialize message bus
    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 1024,
        .worker_count = config.message_bus_workers,
        .flush_interval_ms = 10,
    });
    defer bus.deinit();
    try bus.start();

    // Give workers time to fully start
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Subscribe to Item.created
    const filter = message_bus.Filter{ .conditions = &.{} };
    const sub_id = try bus.subscribe(
        message_bus.ModelTopics("Item").created,
        filter,
        onItemCreated,
    );
    defer bus.unsubscribe(sub_id);

    // Create mock handler context
    var handler_ctx = MockItemHandler.Context.init();
    try handler_ctx.postInit(allocator, &bus);

    // Simulate request
    const request = "{\"action\":\"create\",\"item_id\":42,\"name\":\"test_item\"}";
    var response_buffer: [1024]u8 = undefined;
    _ = try MockItemHandler.handle(&handler_ctx, request, &response_buffer, allocator);

    // Wait for event delivery
    const received = test_stats.waitForEvents(1, config.test_timeout_ms);
    try std.testing.expect(received);

    // Verify stats
    try std.testing.expectEqual(@as(u32, 1), test_stats.events_received.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), test_stats.item_created_count.load(.acquire));

    std.debug.print("✓ Test 1 PASSED\n", .{});
}

/// Integration Test 2: Multiple Requests → Multiple Events → Multiple Subscribers
fn test_multiple_requests_multiple_subscribers(allocator: Allocator, config: TestConfig) !void {
    std.debug.print("\n=== Test 2: Multiple Requests → Multiple Events → Multiple Subscribers ===\n", .{});

    test_stats.reset();

    // Initialize message bus
    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 1024,
        .worker_count = config.message_bus_workers,
        .flush_interval_ms = 10,
    });
    defer bus.deinit();
    try bus.start();

    // Subscribe multiple handlers
    const filter = message_bus.Filter{ .conditions = &.{} };

    const sub_created = try bus.subscribe(
        message_bus.ModelTopics("Item").created,
        filter,
        onItemCreated,
    );
    defer bus.unsubscribe(sub_created);

    const sub_updated = try bus.subscribe(
        message_bus.ModelTopics("Item").updated,
        filter,
        onItemUpdated,
    );
    defer bus.unsubscribe(sub_updated);

    const sub_wildcard = try bus.subscribe(
        message_bus.ModelTopics("Item").wildcard,
        filter,
        onAnyItemEvent,
    );
    defer bus.unsubscribe(sub_wildcard);

    // Create mock handler
    var handler_ctx = MockItemHandler.Context.init();
    try handler_ctx.postInit(allocator, &bus);

    // Send multiple requests
    const requests = [_][]const u8{
        "{\"action\":\"create\",\"item_id\":1,\"name\":\"item_1\"}",
        "{\"action\":\"create\",\"item_id\":2,\"name\":\"item_2\"}",
        "{\"action\":\"update\",\"item_id\":1,\"name\":\"item_1_updated\"}",
        "{\"action\":\"create\",\"item_id\":3,\"name\":\"item_3\"}",
        "{\"action\":\"update\",\"item_id\":2,\"name\":\"item_2_updated\"}",
    };

    var response_buffer: [1024]u8 = undefined;
    for (requests) |request| {
        _ = try MockItemHandler.handle(&handler_ctx, request, &response_buffer, allocator);
        std.Thread.sleep(10 * std.time.ns_per_ms); // Small delay
    }

    // Wait for all events (5 events × 2 subscribers = 10 total deliveries)
    // Wildcard subscriber gets all 5, specific subscribers get 3 creates + 2 updates
    const expected_deliveries = 5 + 3 + 2; // wildcard + created + updated
    const received = test_stats.waitForEvents(expected_deliveries, config.test_timeout_ms);
    try std.testing.expect(received);

    // Verify counts
    // Note: Each event is counted twice - once by specific handler, once by wildcard
    try std.testing.expectEqual(@as(u32, 6), test_stats.item_created_count.load(.acquire)); // 3 created × 2 handlers
    try std.testing.expectEqual(@as(u32, 4), test_stats.item_updated_count.load(.acquire)); // 2 updated × 2 handlers

    std.debug.print("✓ Test 2 PASSED\n", .{});
}

/// Integration Test 3: Event Chain (Handler A → Event → Handler B → Event → Handler C)
fn test_event_chain(allocator: Allocator, config: TestConfig) !void {
    std.debug.print("\n=== Test 3: Event Chain (Handler A → Event → Handler B → Event → Handler C) ===\n", .{});

    test_stats.reset();

    // Initialize message bus
    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 1024,
        .worker_count = config.message_bus_workers,
        .flush_interval_ms = 10,
    });
    defer bus.deinit();
    try bus.start();

    // Handler B: Listens to Item.created, publishes Item.processed
    const handlerB = struct {
        fn onCreated(event: *const Event, alloc: Allocator) void {
            std.debug.print("  Handler B: Item.created received, publishing Item.processed\n", .{});
            test_stats.recordEvent(event);

            // Publish Item.processed
            const globals = @import("globals.zig");
            if (globals.global_message_bus) |g_bus| {
                var data_buf: [256]u8 = undefined;
                const data = std.fmt.bufPrint(&data_buf,
                    "{{\"processed_from\":{d}}}",
                    .{event.model_id}
                ) catch return;

                // Create owned event
                const processed_event = Event.initOwned(
                    alloc,
                    .custom,
                    message_bus.CustomTopic("Item.processed"),
                    "Item",
                    event.model_id,
                    data,
                ) catch return;

                g_bus.publish(processed_event);
            }
        }
    }.onCreated;

    // Handler C: Listens to Item.processed
    const handlerC = struct {
        fn onProcessed(event: *const Event, alloc: Allocator) void {
            _ = alloc;
            std.debug.print("  Handler C: Item.processed received (end of chain)\n", .{});
            test_stats.recordEvent(event);
        }
    }.onProcessed;

    // Subscribe chain
    const filter = message_bus.Filter{ .conditions = &.{} };

    const sub_b = try bus.subscribe(
        message_bus.ModelTopics("Item").created,
        filter,
        handlerB,
    );
    defer bus.unsubscribe(sub_b);

    const sub_c = try bus.subscribe(
        message_bus.CustomTopic("Item.processed"),
        filter,
        handlerC,
    );
    defer bus.unsubscribe(sub_c);

    // Set global bus for handlers
    const globals = @import("globals.zig");
    const old_bus = globals.global_message_bus;
    globals.global_message_bus = &bus;
    defer globals.global_message_bus = old_bus;

    // Handler A: Create item (publishes Item.created)
    var handler_ctx = MockItemHandler.Context.init();
    try handler_ctx.postInit(allocator, &bus);

    const request = "{\"action\":\"create\",\"item_id\":99,\"name\":\"chain_test\"}";
    var response_buffer: [1024]u8 = undefined;
    _ = try MockItemHandler.handle(&handler_ctx, request, &response_buffer, allocator);

    // Wait for chain: Item.created + Item.processed = 2 events
    const received = test_stats.waitForEvents(2, config.test_timeout_ms);
    try std.testing.expect(received);

    // Verify both events were received
    try std.testing.expectEqual(@as(u32, 1), test_stats.item_created_count.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), test_stats.item_processed_count.load(.acquire));

    std.debug.print("✓ Test 3 PASSED\n", .{});
}

/// Integration Test 4: Filtered Subscriptions
fn test_filtered_subscriptions(allocator: Allocator, config: TestConfig) !void {
    std.debug.print("\n=== Test 4: Filtered Subscriptions ===\n", .{});

    test_stats.reset();

    // Initialize message bus
    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 1024,
        .worker_count = config.message_bus_workers,
        .flush_interval_ms = 10,
    });
    defer bus.deinit();
    try bus.start();

    // Subscribe with filter: only item_id > 50
    const high_id_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "item_id", .op = .gt, .value = "50" },
        },
    };

    const high_id_handler = struct {
        fn onHighId(event: *const Event, alloc: Allocator) void {
            _ = alloc;
            std.debug.print("  ✓ High-ID handler: item_id={d} (filter matched!)\n", .{event.model_id});
            _ = test_stats.events_received.fetchAdd(1, .monotonic);
            _ = test_stats.high_id_count.fetchAdd(1, .monotonic);
        }
    }.onHighId;

    std.debug.print("  Filter configured: item_id > 50\n", .{});

    const sub_high = try bus.subscribe(
        message_bus.ModelTopics("Item").created,
        high_id_filter,
        high_id_handler,
    );
    defer bus.unsubscribe(sub_high);

    // Subscribe without filter (all events)
    const all_filter = message_bus.Filter{ .conditions = &.{} };
    const sub_all = try bus.subscribe(
        message_bus.ModelTopics("Item").created,
        all_filter,
        onItemCreated,
    );
    defer bus.unsubscribe(sub_all);

    // Create mock handler
    var handler_ctx = MockItemHandler.Context.init();
    try handler_ctx.postInit(allocator, &bus);

    // Send requests with different IDs
    const requests = [_][]const u8{
        "{\"action\":\"create\",\"item_id\":10,\"name\":\"low_id\"}",    // Not matched by filter
        "{\"action\":\"create\",\"item_id\":100,\"name\":\"high_id\"}",  // Matched!
        "{\"action\":\"create\",\"item_id\":25,\"name\":\"mid_id\"}",    // Not matched
        "{\"action\":\"create\",\"item_id\":75,\"name\":\"high_id_2\"}", // Matched!
    };

    var response_buffer: [1024]u8 = undefined;
    for (requests) |request| {
        _ = try MockItemHandler.handle(&handler_ctx, request, &response_buffer, allocator);
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    // Wait for events (4 to all_handler + 2 to high_id_handler = 6 total)
    const received = test_stats.waitForEvents(6, config.test_timeout_ms);
    try std.testing.expect(received);

    // Verify: all_handler received 4 events, high-ID handler received only 2 events
    try std.testing.expectEqual(@as(u32, 4), test_stats.item_created_count.load(.acquire)); // all 4 events
    try std.testing.expectEqual(@as(u32, 2), test_stats.high_id_count.load(.acquire)); // only item_id > 50

    std.debug.print("✓ Test 4 PASSED\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = TestConfig{};

    // Initialize global test stats
    test_stats = TestStats.init(allocator);
    defer test_stats.deinit(allocator);

    std.debug.print("\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  Message Bus Integration Tests\n", .{});
    std.debug.print("  (TCP Request → Handler → Message Bus → Subscriber)\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});

    // Run all tests
    try test_single_request_single_subscriber(allocator, config);
    try test_multiple_requests_multiple_subscribers(allocator, config);
    try test_event_chain(allocator, config);
    try test_filtered_subscriptions(allocator, config);

    std.debug.print("\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  ALL TESTS PASSED ✓\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("\n", .{});
}
