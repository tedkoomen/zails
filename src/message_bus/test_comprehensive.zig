/// Comprehensive test suite for message bus components
const std = @import("std");
const testing = std.testing;
const Event = @import("../event.zig").Event;
const generateEventId = @import("../event.zig").generateEventId;
const Filter = @import("filter.zig").Filter;

// ============================================================================
// Event Tests
// ============================================================================

test "Event: initOwned allocates and owns data" {
    const allocator = testing.allocator;

    const event = try Event.initOwned(
        allocator,
        .model_created,
        "Test.topic",
        "TestModel",
        123,
        "{\"test\":\"data\"}",
    );
    defer event.deinit(allocator);

    try testing.expect(event.owned);
    try testing.expectEqualStrings("Test.topic", event.topic);
    try testing.expectEqualStrings("TestModel", event.model_type);
    try testing.expectEqual(@as(u64, 123), event.model_id);
    try testing.expectEqualStrings("{\"test\":\"data\"}", event.data);
}

test "Event: deinit only frees owned events" {
    const allocator = testing.allocator;

    // Non-owned event
    const event1 = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "test",
        .model_type = "test",
        .model_id = 1,
        .data = "{}",
        .owned = false,
    };
    event1.deinit(allocator); // Should not free anything

    // Owned event
    const event2 = try Event.initOwned(allocator, .model_created, "test", "test", 1, "{}");
    defer event2.deinit(allocator); // Should free

    try testing.expect(!event1.owned);
    try testing.expect(event2.owned);
}

test "Event: generateEventId produces unique IDs" {
    const id1 = generateEventId();
    const id2 = generateEventId();
    const id3 = generateEventId();

    try testing.expect(id1 != id2);
    try testing.expect(id2 != id3);
    try testing.expect(id1 != id3);
}

test "Event: serialize and deserialize roundtrip" {
    const allocator = testing.allocator;

    const original = Event{
        .id = 0x12345678_9abcdef0_12345678_9abcdef0,
        .timestamp = 1709568000000000,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 42,
        .data = "{\"key\":\"value\"}",
        .owned = false,
    };

    var buffer: [4096]u8 = undefined;
    const serialized = try original.serialize(&buffer);

    const deserialized = try Event.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);

    try testing.expectEqual(original.id, deserialized.id);
    try testing.expectEqual(original.timestamp, deserialized.timestamp);
    try testing.expectEqual(original.event_type, deserialized.event_type);
    try testing.expectEqualStrings(original.topic, deserialized.topic);
    try testing.expectEqualStrings(original.model_type, deserialized.model_type);
    try testing.expectEqual(original.model_id, deserialized.model_id);
    try testing.expectEqualStrings(original.data, deserialized.data);
    try testing.expect(deserialized.owned); // Deserialized events are owned
}

// ============================================================================
// Filter Tests
// ============================================================================

test "Filter: empty filter matches all events" {
    const allocator = testing.allocator;

    const filter = Filter{ .conditions = &.{} };

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{\"price\":150}",
        .owned = false,
    };

    const result = try filter.matches(&event, allocator);
    try testing.expect(result);
}

test "Filter: string equality" {
    const allocator = testing.allocator;

    const filter = Filter{
        .conditions = &.{
            .{ .field = "name", .op = .eq, .value = "test" },
        },
    };

    const event1 = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{\"name\":\"test\"}",
        .owned = false,
    };

    const event2 = Event{
        .id = 2,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 2,
        .data = "{\"name\":\"other\"}",
        .owned = false,
    };

    try testing.expect(try filter.matches(&event1, allocator));
    try testing.expect(!try filter.matches(&event2, allocator));
}

test "Filter: integer comparisons" {
    const allocator = testing.allocator;

    const filter_gt = Filter{
        .conditions = &.{
            .{ .field = "value", .op = .gt, .value = "50" },
        },
    };

    const filter_lt = Filter{
        .conditions = &.{
            .{ .field = "value", .op = .lt, .value = "50" },
        },
    };

    const event_high = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{\"value\":100}",
        .owned = false,
    };

    const event_low = Event{
        .id = 2,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 2,
        .data = "{\"value\":10}",
        .owned = false,
    };

    try testing.expect(try filter_gt.matches(&event_high, allocator));
    try testing.expect(!try filter_gt.matches(&event_low, allocator));
    try testing.expect(!try filter_lt.matches(&event_high, allocator));
    try testing.expect(try filter_lt.matches(&event_low, allocator));
}

test "Filter: multiple conditions (AND logic)" {
    const allocator = testing.allocator;

    const filter = Filter{
        .conditions = &.{
            .{ .field = "status", .op = .eq, .value = "active" },
            .{ .field = "priority", .op = .gte, .value = "5" },
        },
    };

    const event_match = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{\"status\":\"active\",\"priority\":7}",
        .owned = false,
    };

    const event_partial = Event{
        .id = 2,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 2,
        .data = "{\"status\":\"active\",\"priority\":3}",
        .owned = false,
    };

    try testing.expect(try filter.matches(&event_match, allocator));
    try testing.expect(!try filter.matches(&event_partial, allocator));
}

test "Filter: nested field access" {
    const allocator = testing.allocator;

    const filter = Filter{
        .conditions = &.{
            .{ .field = "user.name", .op = .eq, .value = "john" },
        },
    };

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{\"user\":{\"name\":\"john\",\"age\":30}}",
        .owned = false,
    };

    try testing.expect(try filter.matches(&event, allocator));
}

test "Filter: invalid JSON returns false" {
    const allocator = testing.allocator;

    const filter = Filter{
        .conditions = &.{
            .{ .field = "value", .op = .gt, .value = "50" },
        },
    };

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "invalid json{{{",
        .owned = false,
    };

    try testing.expect(!try filter.matches(&event, allocator));
}

test "Filter: missing field returns false" {
    const allocator = testing.allocator;

    const filter = Filter{
        .conditions = &.{
            .{ .field = "missing_field", .op = .eq, .value = "value" },
        },
    };

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{\"other_field\":\"value\"}",
        .owned = false,
    };

    try testing.expect(!try filter.matches(&event, allocator));
}

// ============================================================================
// Ring Buffer Edge Cases (would need to import ring_buffer.zig)
// ============================================================================

// Note: These tests would require importing ring_buffer.zig which has
// import path issues in standalone tests. The integration tests cover
// ring buffer functionality thoroughly.

// ============================================================================
// Summary
// ============================================================================

// This test file covers:
// ✓ Event ownership and lifecycle
// ✓ Event serialization/deserialization
// ✓ Filter evaluation (empty, string, integer, multiple conditions)
// ✓ Filter edge cases (invalid JSON, missing fields, nested fields)
// ✓ ID generation uniqueness
//
// Additional coverage is provided by:
// - src/integration_test.zig (end-to-end tests)
// - Individual module tests in message_bus/*.zig files
