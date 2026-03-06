/// Event Builder - Simplified API for creating and publishing events
///
/// Benefits:
/// - Handlers don't need to know Event internals
/// - Compile-time topic validation
/// - Simple, fluent API
/// - Automatic ID and timestamp generation

const std = @import("std");
const Event = @import("../event.zig").Event;
const generateEventId = @import("../event.zig").generateEventId;
const MessageBus = @import("message_bus.zig").MessageBus;
const model_topics = @import("model_topics.zig");
const validateTopicFormat = model_topics.validateTopicFormat;

/// Event Builder - Fluent API for creating events
pub const EventBuilder = struct {
    const Self = @This();

    event: Event,

    /// Create a new event with compile-time validated topic
    pub fn init(comptime topic: []const u8) Self {
        // Compile-time validation - fails at compile time if topic format is invalid
        validateTopicFormat(topic);

        return Self{
            .event = Event{
                .id = generateEventId(),
                .timestamp = std.time.microTimestamp(),
                .event_type = .custom, // Default to custom
                .topic = topic,
                .model_type = "",
                .model_id = 0,
                .data = "",
            },
        };
    }

    /// Set model type (e.g., "User", "Item", "Order")
    pub fn modelType(self: Self, model_type: []const u8) Self {
        var result = self;
        result.event.model_type = model_type;
        return result;
    }

    /// Set model ID
    pub fn modelId(self: Self, model_id: u64) Self {
        var result = self;
        result.event.model_id = model_id;
        return result;
    }

    /// Set event data (JSON string or serialized data)
    pub fn data(self: Self, event_data: []const u8) Self {
        var result = self;
        result.event.data = event_data;
        return result;
    }

    /// Set event type
    pub fn eventType(self: Self, event_type: Event.EventType) Self {
        var result = self;
        result.event.event_type = event_type;
        return result;
    }

    /// Build and return the event
    pub fn build(self: Self) Event {
        return self.event;
    }

    /// Build and publish to message bus (convenience method)
    pub fn publish(self: Self, bus: *MessageBus) void {
        bus.publish(self.event);
    }
};

/// Simple helper: Publish event to global message bus
/// Handlers can use this without knowing about Event internals
pub fn publishEvent(comptime topic: []const u8, data: []const u8) void {
    const globals = @import("../globals.zig");
    if (globals.global_message_bus) |bus| {
        EventBuilder.init(topic)
            .data(data)
            .publish(bus);
    }
}

/// Helper: Publish model event with full context
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
