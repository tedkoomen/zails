/// Event Builder - Simplified API for creating and publishing events
///
/// Benefits:
/// - Handlers don't need to know Event internals
/// - Compile-time topic validation
/// - Simple, fluent API
/// - Automatic ID and timestamp generation
const std = @import("std");
const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const FieldValue = event_mod.FieldValue;
const FixedString = event_mod.FixedString;
const generateEventId = event_mod.generateEventId;
const MessageBus = @import("message_bus.zig").MessageBus;
const model_topics = @import("model_topics.zig");
const validateTopicFormat = model_topics.validateTopicFormat;

pub const EventBuilder = struct {
    const Self = @This();

    event: Event,

    pub fn init(comptime topic: []const u8) Self {
        validateTopicFormat(topic);

        return Self{
            .event = Event{
                .id = generateEventId(),
                .timestamp = std.time.microTimestamp(),
                .event_type = .custom,
                .topic = topic,
                .model_type = "",
                .model_id = 0,
                .data = "",
            },
        };
    }

    pub fn modelType(self: Self, model_type: []const u8) Self {
        var result = self;
        result.event.model_type = model_type;
        return result;
    }

    pub fn modelId(self: Self, model_id: u64) Self {
        var result = self;
        result.event.model_id = model_id;
        return result;
    }

    pub fn data(self: Self, event_data: []const u8) Self {
        var result = self;
        result.event.data = event_data;
        return result;
    }

    pub fn eventType(self: Self, event_type: Event.EventType) Self {
        var result = self;
        result.event.event_type = event_type;
        return result;
    }

    pub fn field(self: Self, name: []const u8, value: FieldValue) Self {
        var result = self;
        result.event.setField(name, value);
        return result;
    }

    pub fn stringField(self: Self, name: []const u8, value: []const u8) Self {
        return self.field(name, .{ .string = FixedString.init(value) });
    }

    pub fn intField(self: Self, name: []const u8, value: i64) Self {
        return self.field(name, .{ .int = value });
    }

    pub fn floatField(self: Self, name: []const u8, value: f64) Self {
        return self.field(name, .{ .float = value });
    }

    pub fn boolField(self: Self, name: []const u8, value: bool) Self {
        return self.field(name, .{ .boolean = value });
    }

    pub fn build(self: Self) Event {
        return self.event;
    }

    pub fn publish(self: Self, bus: *MessageBus) void {
        bus.publish(self.event);
    }
};

pub fn publishEvent(comptime topic: []const u8, data: []const u8) void {
    const globals = @import("../globals.zig");
    if (globals.global_message_bus) |bus| {
        EventBuilder.init(topic)
            .data(data)
            .publish(bus);
    }
}

pub fn publishModelEvent(
    comptime topic: []const u8,
    model_type: []const u8,
    model_id: u64,
    data: []const u8,
) void {
    validateTopicFormat(topic);

    const globals = @import("../globals.zig");
    if (globals.global_message_bus) |bus| {
        EventBuilder.init(topic)
            .modelType(model_type)
            .modelId(model_id)
            .data(data)
            .publish(bus);
    }
}

// ====================
// Tests
// ====================

test "event builder creates valid event" {
    const ItemTopics = model_topics.ModelTopics("Item");
    const event = EventBuilder.init(ItemTopics.created)
        .modelType("Item")
        .modelId(42)
        .data("{\"name\":\"widget\"}")
        .build();

    try std.testing.expectEqualStrings(ItemTopics.created, event.topic);
    try std.testing.expectEqualStrings(event.model_type, "Item");
    try std.testing.expectEqual(@as(u64, 42), event.model_id);
    try std.testing.expectEqualStrings(event.data, "{\"name\":\"widget\"}");
}

test "event builder validates topic at compile time" {
    const UserTopics = model_topics.ModelTopics("User");
    // This compiles because topic is valid
    const event = EventBuilder.init(UserTopics.created).build();
    try std.testing.expectEqualStrings(UserTopics.created, event.topic);

    // This would fail at compile time (uncomment to test):
    // const bad_event = EventBuilder.init("InvalidTopic").build();
}

test "event builder typed field setters" {
    const TradeTopics = model_topics.ModelTopics("Trade");
    const event = EventBuilder.init(TradeTopics.created)
        .modelType("Trade")
        .modelId(1)
        .stringField("symbol", "AAPL")
        .intField("price", 15000)
        .floatField("ratio", 1.5)
        .boolField("active", true)
        .build();

    // Verify typed fields
    const symbol = event.getField("symbol") orelse unreachable;
    try std.testing.expectEqualStrings("AAPL", symbol.string.slice());

    const price = event.getField("price") orelse unreachable;
    try std.testing.expectEqual(@as(i64, 15000), price.int);

    const ratio = event.getField("ratio") orelse unreachable;
    try std.testing.expectEqual(@as(f64, 1.5), ratio.float);

    const active = event.getField("active") orelse unreachable;
    try std.testing.expectEqual(true, active.boolean);

    // Non-existent field returns null
    try std.testing.expect(event.getField("nonexistent") == null);
}
