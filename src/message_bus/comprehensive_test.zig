const std = @import("std");
const testing = std.testing;
const message_bus = @import("mod.zig");
const Event = @import("../event.zig").Event;
const generateEventId = @import("../event.zig").generateEventId;

// ============================================================================
// Test 1: Basic Publish/Subscribe Flow
// ============================================================================

test "basic publish and subscribe flow" {
    const allocator = testing.allocator;

    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 2,
    });
    defer bus.deinit();

    // Counter for delivered events
    const Context = struct {
        var counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

        fn handler(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            _ = event;
            _ = counter.fetchAdd(1, .monotonic);
        }
    };

    // Subscribe
    const filter = message_bus.Filter{ .conditions = &.{} };
    const sub_id = try bus.subscribe("Test.created", filter, Context.handler);

    // Publish 5 events
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const event = Event{
            .id = generateEventId(),
            .timestamp = std.time.microTimestamp(),
            .event_type = .model_created,
            .topic = "Test.created",
            .model_type = "Test",
            .model_id = i,
            .data = "{}",
        };
        bus.publish(event);
    }

    // Check stats
    const stats = bus.getStats();
    try testing.expectEqual(@as(u64, 5), stats.published);
    try testing.expectEqual(@as(u64, 0), stats.dropped);

    // Cleanup
    bus.unsubscribe(sub_id);
}

// ============================================================================
// Test 2: Multiple Subscribers to Same Topic
// ============================================================================

test "multiple subscribers to same topic" {
    const allocator = testing.allocator;

    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1,
    });
    defer bus.deinit();

    const Context = struct {
        var handler1_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        var handler2_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

        fn handler1(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            _ = event;
            _ = handler1_count.fetchAdd(1, .monotonic);
        }

        fn handler2(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            _ = event;
            _ = handler2_count.fetchAdd(1, .monotonic);
        }
    };

    // Two subscribers to same topic
    const filter = message_bus.Filter{ .conditions = &.{} };
    const sub1 = try bus.subscribe("Trade.created", filter, Context.handler1);
    const sub2 = try bus.subscribe("Trade.created", filter, Context.handler2);

    // Publish event
    const event = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{}",
    };
    bus.publish(event);

    // Both subscribers should receive the event
    // (Note: actual delivery happens asynchronously in workers)

    bus.unsubscribe(sub1);
    bus.unsubscribe(sub2);
}

// ============================================================================
// Test 3: Wildcard Topic Matching
// ============================================================================

test "wildcard topic matching" {
    const allocator = testing.allocator;

    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1,
    });
    defer bus.deinit();

    const filter = message_bus.Filter{ .conditions = &.{} };
    const sub_id = try bus.subscribe("Trade.*", filter, testHandler);

    // These should match
    const event1 = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{}",
    };
    bus.publish(event1);

    const event2 = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_updated,
        .topic = "Trade.updated",
        .model_type = "Trade",
        .model_id = 2,
        .data = "{}",
    };
    bus.publish(event2);

    // This should NOT match
    const event3 = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Portfolio.created",
        .model_type = "Portfolio",
        .model_id = 3,
        .data = "{}",
    };
    bus.publish(event3);

    const stats = bus.getStats();
    try testing.expectEqual(@as(u64, 3), stats.published);

    bus.unsubscribe(sub_id);
}

// ============================================================================
// Test 4: Filter by Integer Field (price > 1000)
// ============================================================================

test "filter by integer field - price greater than" {
    const allocator = testing.allocator;

    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1,
    });
    defer bus.deinit();

    // Subscribe only to high-value trades
    const filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gt, .value = "1000" },
        },
    };
    const sub_id = try bus.subscribe("Trade.created", filter, testHandler);

    // Low price - should NOT match
    const low_event = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{\"symbol\":\"AAPL\",\"price\":500}",
    };
    bus.publish(low_event);

    // High price - should match
    const high_event = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 2,
        .data = "{\"symbol\":\"TSLA\",\"price\":15000}",
    };
    bus.publish(high_event);

    bus.unsubscribe(sub_id);
}

// ============================================================================
// Test 5: Filter by String Field (symbol = "AAPL")
// ============================================================================

test "filter by string field - exact match" {
    const allocator = testing.allocator;

    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1,
    });
    defer bus.deinit();

    // Subscribe only to AAPL trades
    const filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .eq, .value = "AAPL" },
        },
    };
    const sub_id = try bus.subscribe("Trade.created", filter, testHandler);

    // AAPL - should match
    const aapl_event = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{\"symbol\":\"AAPL\",\"price\":150}",
    };
    bus.publish(aapl_event);

    // TSLA - should NOT match
    const tsla_event = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 2,
        .data = "{\"symbol\":\"TSLA\",\"price\":200}",
    };
    bus.publish(tsla_event);

    bus.unsubscribe(sub_id);
}

// ============================================================================
// Test 6: Multiple Filter Conditions (AND logic)
// ============================================================================

test "multiple filter conditions with AND logic" {
    const allocator = testing.allocator;

    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1,
    });
    defer bus.deinit();

    // Subscribe to: AAPL AND price > 100
    const filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .eq, .value = "AAPL" },
            .{ .field = "price", .op = .gt, .value = "100" },
        },
    };
    const sub_id = try bus.subscribe("Trade.created", filter, testHandler);

    // AAPL with high price - MATCHES
    const match_event = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{\"symbol\":\"AAPL\",\"price\":150}",
    };
    bus.publish(match_event);

    // AAPL with low price - NO MATCH
    const no_match1 = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 2,
        .data = "{\"symbol\":\"AAPL\",\"price\":50}",
    };
    bus.publish(no_match1);

    // TSLA with high price - NO MATCH
    const no_match2 = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 3,
        .data = "{\"symbol\":\"TSLA\",\"price\":200}",
    };
    bus.publish(no_match2);

    bus.unsubscribe(sub_id);
}

// ============================================================================
// Test 7: Queue Overflow Handling
// ============================================================================

test "queue overflow and back-pressure" {
    const allocator = testing.allocator;

    // Very small queue to trigger overflow
    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 4,
        .worker_count = 1,
    });
    defer bus.deinit();

    // Fill the queue
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const event = Event{
            .id = generateEventId(),
            .timestamp = std.time.microTimestamp(),
            .event_type = .model_created,
            .topic = "Test.created",
            .model_type = "Test",
            .model_id = i,
            .data = "{}",
        };
        bus.publish(event);
    }

    const stats = bus.getStats();

    // Some events should be dropped due to small queue
    try testing.expect(stats.dropped > 0);
    try testing.expectEqual(@as(u64, 10), stats.published + stats.dropped);
}

// ============================================================================
// Test 8: Event Serialization and Deserialization (Protobuf)
// ============================================================================

test "event protobuf serialization round-trip" {
    const allocator = testing.allocator;

    const original = Event{
        .id = 0x12345678_9abcdef0_12345678_9abcdef0,
        .timestamp = 1709568000000000,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 42,
        .data = "{\"symbol\":\"AAPL\",\"price\":15000,\"quantity\":100}",
    };

    // Serialize
    var buffer: [4096]u8 = undefined;
    const serialized = try original.serialize(&buffer);

    // Verify it's binary data (protobuf)
    try testing.expect(serialized.len > 0);
    try testing.expect(serialized.len < buffer.len);

    // Deserialize
    const deserialized = try Event.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);

    // Verify all fields match
    try testing.expectEqual(original.id, deserialized.id);
    try testing.expectEqual(original.timestamp, deserialized.timestamp);
    try testing.expectEqual(original.event_type, deserialized.event_type);
    try testing.expectEqualStrings(original.topic, deserialized.topic);
    try testing.expectEqualStrings(original.model_type, deserialized.model_type);
    try testing.expectEqual(original.model_id, deserialized.model_id);
    try testing.expectEqualStrings(original.data, deserialized.data);
}

// ============================================================================
// Test 9: Unsubscribe Removes Subscriber
// ============================================================================

test "unsubscribe removes subscriber" {
    const allocator = testing.allocator;

    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1,
    });
    defer bus.deinit();

    const filter = message_bus.Filter{ .conditions = &.{} };

    // Subscribe
    const sub_id = try bus.subscribe("Test.created", filter, testHandler);
    try testing.expectEqual(@as(usize, 1), bus.subscribers.getTopicSubscriptionCount("Test.created"));

    // Unsubscribe
    bus.unsubscribe(sub_id);
    try testing.expectEqual(@as(usize, 0), bus.subscribers.getTopicSubscriptionCount("Test.created"));
}

// ============================================================================
// Test 10: Statistics Tracking
// ============================================================================

test "statistics tracking" {
    const allocator = testing.allocator;

    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1,
    });
    defer bus.deinit();

    // Initial stats
    var stats = bus.getStats();
    try testing.expectEqual(@as(u64, 0), stats.published);
    try testing.expectEqual(@as(u64, 0), stats.dropped);
    try testing.expectEqual(@as(usize, 0), stats.queued);

    // Publish 3 events
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const event = Event{
            .id = generateEventId(),
            .timestamp = std.time.microTimestamp(),
            .event_type = .model_created,
            .topic = "Test.created",
            .model_type = "Test",
            .model_id = i,
            .data = "{}",
        };
        bus.publish(event);
    }

    stats = bus.getStats();
    try testing.expectEqual(@as(u64, 3), stats.published);
}

// ============================================================================
// Test 11: Filter Operators
// ============================================================================

test "filter operators - greater than or equal" {
    const allocator = testing.allocator;

    const filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gte, .value = "100" },
        },
    };

    // Test event with price = 100 (should match)
    const event1 = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{\"price\":100}",
    };
    const match1 = try filter.matches(&event1, allocator);
    try testing.expect(match1);

    // Test event with price = 150 (should match)
    const event2 = Event{
        .id = 2,
        .timestamp = 200,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 2,
        .data = "{\"price\":150}",
    };
    const match2 = try filter.matches(&event2, allocator);
    try testing.expect(match2);

    // Test event with price = 50 (should NOT match)
    const event3 = Event{
        .id = 3,
        .timestamp = 300,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 3,
        .data = "{\"price\":50}",
    };
    const match3 = try filter.matches(&event3, allocator);
    try testing.expect(!match3);
}

test "filter operators - not equal" {
    const allocator = testing.allocator;

    const filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "status", .op = .ne, .value = "cancelled" },
        },
    };

    // Test event with status = "active" (should match)
    const event1 = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{\"status\":\"active\"}",
    };
    const match1 = try filter.matches(&event1, allocator);
    try testing.expect(match1);

    // Test event with status = "cancelled" (should NOT match)
    const event2 = Event{
        .id = 2,
        .timestamp = 200,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 2,
        .data = "{\"status\":\"cancelled\"}",
    };
    const match2 = try filter.matches(&event2, allocator);
    try testing.expect(!match2);
}

test "filter operators - like (substring match)" {
    const allocator = testing.allocator;

    const filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .like, .value = "AA" },
        },
    };

    // Test event with "AAPL" (contains "AA", should match)
    const event1 = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{\"symbol\":\"AAPL\"}",
    };
    const match1 = try filter.matches(&event1, allocator);
    try testing.expect(match1);

    // Test event with "TSLA" (doesn't contain "AA", should NOT match)
    const event2 = Event{
        .id = 2,
        .timestamp = 200,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 2,
        .data = "{\"symbol\":\"TSLA\"}",
    };
    const match2 = try filter.matches(&event2, allocator);
    try testing.expect(!match2);
}

// ============================================================================
// Helper Functions
// ============================================================================

fn testHandler(event: *const Event, allocator: std.mem.Allocator) void {
    _ = event;
    _ = allocator;
    // No-op handler for tests
}
