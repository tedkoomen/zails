/// Comprehensive test suite for message bus components
const std = @import("std");
const testing = std.testing;
const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const FixedString = event_mod.FixedString;
const generateEventId = event_mod.generateEventId;
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
        .data = "",
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
    const filter = Filter{ .conditions = &.{} };

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "",
        .owned = false,
    };

    const result = filter.matches(&event);
    try testing.expect(result);
}

test "Filter: string equality" {
    const filter = Filter{
        .conditions = &.{
            .{ .field = "name", .op = .eq, .value = "test" },
        },
    };

    var event1 = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "",
        .owned = false,
    };
    event1.setField("name", .{ .string = FixedString.init("test") });

    var event2 = Event{
        .id = 2,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 2,
        .data = "",
        .owned = false,
    };
    event2.setField("name", .{ .string = FixedString.init("other") });

    try testing.expect(filter.matches(&event1));
    try testing.expect(!filter.matches(&event2));
}

test "Filter: integer comparisons" {
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

    var event_high = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "",
        .owned = false,
    };
    event_high.setField("value", .{ .int = 100 });

    var event_low = Event{
        .id = 2,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 2,
        .data = "",
        .owned = false,
    };
    event_low.setField("value", .{ .int = 10 });

    try testing.expect(filter_gt.matches(&event_high));
    try testing.expect(!filter_gt.matches(&event_low));
    try testing.expect(!filter_lt.matches(&event_high));
    try testing.expect(filter_lt.matches(&event_low));
}

test "Filter: multiple conditions (AND logic)" {
    const filter = Filter{
        .conditions = &.{
            .{ .field = "status", .op = .eq, .value = "active" },
            .{ .field = "priority", .op = .gte, .value = "5" },
        },
    };

    var event_match = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "",
        .owned = false,
    };
    event_match.setField("status", .{ .string = FixedString.init("active") });
    event_match.setField("priority", .{ .int = 7 });

    var event_partial = Event{
        .id = 2,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 2,
        .data = "",
        .owned = false,
    };
    event_partial.setField("status", .{ .string = FixedString.init("active") });
    event_partial.setField("priority", .{ .int = 3 });

    try testing.expect(filter.matches(&event_match));
    try testing.expect(!filter.matches(&event_partial));
}

test "Filter: missing field returns false" {
    const filter = Filter{
        .conditions = &.{
            .{ .field = "missing_field", .op = .eq, .value = "value" },
        },
    };

    var event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "",
        .owned = false,
    };
    event.setField("other_field", .{ .string = FixedString.init("value") });

    try testing.expect(!filter.matches(&event));
}

test "Filter: no fields set returns false for non-empty filter" {
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
        .data = "",
        .owned = false,
    };

    try testing.expect(!filter.matches(&event));
}

// ============================================================================
// Summary
// ============================================================================

// This test file covers:
// ✓ Event ownership and lifecycle
// ✓ Event serialization/deserialization
// ✓ Filter evaluation (empty, string, integer, multiple conditions)
// ✓ Filter edge cases (missing fields, no fields set)
// ✓ ID generation uniqueness
//
// Additional coverage is provided by:
// - src/integration_test.zig (end-to-end tests)
// - Individual module tests in message_bus/*.zig files
