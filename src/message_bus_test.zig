const std = @import("std");
const testing = std.testing;

// Import all message bus components
const message_bus = @import("message_bus/mod.zig");
const Event = @import("event.zig").Event;
const generateEventId = @import("event.zig").generateEventId;

test "message bus full integration" {
    const allocator = testing.allocator;

    // Initialize message bus
    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 2,
    });
    defer bus.deinit();

    // Test handler (counts events)
    const TestContext = struct {
        var event_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

        fn handler(event: *const Event, alloc: std.mem.Allocator) void {
            _ = event;
            _ = alloc;
            _ = event_count.fetchAdd(1, .monotonic);
        }
    };

    // Subscribe to events
    const filter = message_bus.Filter{ .conditions = &.{} };
    const sub_id = try bus.subscribe("Test.created", filter, TestContext.handler);
    defer bus.unsubscribe(sub_id);

    // Publish event
    const event = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{\"value\":42}",
    };

    bus.publish(event);

    // Check stats
    const stats = bus.getStats();
    try testing.expectEqual(@as(u64, 1), stats.published);
    try testing.expectEqual(@as(u64, 0), stats.dropped);
}

test "message bus with filters" {
    const allocator = testing.allocator;

    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1,
    });
    defer bus.deinit();

    const TestContext = struct {
        var high_value_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

        fn highValueHandler(event: *const Event, alloc: std.mem.Allocator) void {
            _ = event;
            _ = alloc;
            _ = high_value_count.fetchAdd(1, .monotonic);
        }
    };

    // Subscribe only to high-value trades (price > 1000)
    const filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gt, .value = "1000" },
        },
    };
    const sub_id = try bus.subscribe("Trade.created", filter, TestContext.highValueHandler);
    defer bus.unsubscribe(sub_id);

    // Publish low-value trade (should not match)
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

    // Publish high-value trade (should match)
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

    const stats = bus.getStats();
    try testing.expectEqual(@as(u64, 2), stats.published);
}

test "event ring buffer operations" {
    const allocator = testing.allocator;

    var buffer = try message_bus.EventRingBuffer.init(allocator, 4);
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

    // Push and pop
    try testing.expect(buffer.push(event1));
    try testing.expectEqual(@as(usize, 1), buffer.size());

    const popped = buffer.pop().?;
    try testing.expectEqual(@as(u128, 1), popped.id);
    try testing.expect(buffer.isEmpty());
}

fn registryTestHandler(event: *const Event, alloc: std.mem.Allocator) void {
    _ = event;
    _ = alloc;
}

test "subscriber registry operations" {
    const allocator = testing.allocator;

    var registry = message_bus.SubscriberRegistry.init(allocator);
    defer registry.deinit();

    const filter = message_bus.Filter{ .conditions = &.{} };
    const id = try registry.subscribe("Test.created", filter, registryTestHandler);

    try testing.expectEqual(@as(usize, 1), registry.getTopicSubscriptionCount("Test.created"));

    registry.unsubscribe(id);
    try testing.expectEqual(@as(usize, 0), registry.getTopicSubscriptionCount("Test.created"));
}

test "event serialization with protobuf" {
    const allocator = testing.allocator;

    const event = Event{
        .id = 0x12345678_9abcdef0_12345678_9abcdef0,
        .timestamp = 1709568000000000,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 42,
        .data = "{\"symbol\":\"AAPL\",\"price\":15000}",
    };

    // Serialize to protobuf
    var buffer: [4096]u8 = undefined;
    const serialized = try event.serialize(&buffer);

    // Deserialize
    const deserialized = try Event.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);

    // Verify all fields
    try testing.expectEqual(event.id, deserialized.id);
    try testing.expectEqual(event.timestamp, deserialized.timestamp);
    try testing.expectEqual(event.event_type, deserialized.event_type);
    try testing.expectEqualStrings(event.topic, deserialized.topic);
    try testing.expectEqualStrings(event.model_type, deserialized.model_type);
    try testing.expectEqual(event.model_id, deserialized.model_id);
    try testing.expectEqualStrings(event.data, deserialized.data);
}
