/// Global state shared across modules
/// This avoids circular dependencies in the module system
const std = @import("std");
const Allocator = std.mem.Allocator;
const config_system = @import("config_system.zig");
const metrics_mod = @import("metrics.zig");
const async_clickhouse = @import("async_clickhouse.zig");
const message_bus_mod = @import("message_bus/mod.zig");

/// Global runtime controller for metrics and profiling
/// Set by main.zig during initialization
pub var global_runtime_controller: ?*config_system.RuntimeController = null;

/// Global metrics registry
/// Set by main.zig during initialization
pub var global_metrics: ?*metrics_mod.MetricsRegistry = null;

/// Global ClickHouse writer for request metrics
/// Set by main.zig during initialization
pub var global_clickhouse: ?*async_clickhouse.AsyncClickHouseWriter = null;

/// Global message bus for event-driven architecture
/// Set by main.zig during initialization
pub var global_message_bus: ?*message_bus_mod.MessageBus = null;

/// Global feed manager for UDP exchange feeds
/// Type-erased because FeedManager is parameterized by comptime protocol tuple
/// Set by main.zig during initialization
pub var global_feed_manager: ?*anyopaque = null;

pub const ExternalEventType = enum(u8) {
    model_created = 0,
    model_updated = 1,
    model_deleted = 2,
    custom = 255,
};

pub const ExternalEvent = struct {
    id: u128,
    timestamp: i64,
    event_type: ExternalEventType,
    topic: []const u8,
    model_type: []const u8,
    model_id: u64,
    data: []const u8,
};

pub const ExternalEventCallback = *const fn (event: *const ExternalEvent) void;

const MAX_EXTERNAL_EVENT_BRIDGE_SUBSCRIPTIONS = 64;
const MAX_EXTERNAL_EVENT_TOPIC_LEN = 128;

const ExternalEventBridgeSlot = struct {
    active: bool = false,
    id: u64 = 0,
    topic: [MAX_EXTERNAL_EVENT_TOPIC_LEN]u8 = undefined,
    topic_len: usize = 0,
    callback: ?ExternalEventCallback = null,
    bus_subscription_id: message_bus_mod.SubscriptionId = 0,

    fn topicSlice(self: *const ExternalEventBridgeSlot) []const u8 {
        return self.topic[0..self.topic_len];
    }
};

var external_event_lock = std.Thread.Mutex{};
var next_external_event_subscription_id: u64 = 1;
var external_event_slots: [MAX_EXTERNAL_EVENT_BRIDGE_SUBSCRIPTIONS]ExternalEventBridgeSlot =
    [_]ExternalEventBridgeSlot{.{}} ** MAX_EXTERNAL_EVENT_BRIDGE_SUBSCRIPTIONS;

pub fn subscribeExternalEvent(topic: []const u8, callback: ExternalEventCallback) !u64 {
    if (topic.len == 0 or topic.len > MAX_EXTERNAL_EVENT_TOPIC_LEN) {
        return error.InvalidTopic;
    }

    const bus = global_message_bus orelse return error.BusUnavailable;

    external_event_lock.lock();
    defer external_event_lock.unlock();

    const bus_subscription_id = try bus.subscribe(
        topic,
        message_bus_mod.Filter{ .conditions = &.{} },
        handleExternalBusEvent,
    );

    for (&external_event_slots) |*slot| {
        if (!slot.active) {
            const id = next_external_event_subscription_id;
            next_external_event_subscription_id += 1;

            slot.* = .{
                .active = true,
                .id = id,
                .topic_len = topic.len,
                .callback = callback,
                .bus_subscription_id = bus_subscription_id,
            };
            @memcpy(slot.topic[0..topic.len], topic);
            return id;
        }
    }

    bus.unsubscribe(bus_subscription_id);
    return error.SubscriptionLimitReached;
}

pub fn unsubscribeExternalEvent(subscription_id: u64) bool {
    external_event_lock.lock();
    defer external_event_lock.unlock();

    for (&external_event_slots) |*slot| {
        if (slot.active and slot.id == subscription_id) {
            if (global_message_bus) |bus| {
                bus.unsubscribe(slot.bus_subscription_id);
            }
            slot.* = .{};
            return true;
        }
    }

    return false;
}

pub fn publishExternalEvent(
    event_type: ExternalEventType,
    topic: []const u8,
    model_type: []const u8,
    model_id: u64,
    data: []const u8,
) !void {
    const bus = global_message_bus orelse return error.BusUnavailable;
    const event = try message_bus_mod.Event.initOwned(
        bus.allocator,
        toBusEventType(event_type),
        topic,
        model_type,
        model_id,
        data,
    );
    bus.publish(event);
}

fn handleExternalBusEvent(event: *const message_bus_mod.Event, allocator: Allocator) void {
    _ = allocator;

    var callbacks: [MAX_EXTERNAL_EVENT_BRIDGE_SUBSCRIPTIONS]ExternalEventCallback = undefined;
    var callback_count: usize = 0;

    external_event_lock.lock();
    for (&external_event_slots) |*slot| {
        if (slot.active and slot.callback != null and topicMatches(slot.topicSlice(), event.topic)) {
            callbacks[callback_count] = slot.callback.?;
            callback_count += 1;
        }
    }
    external_event_lock.unlock();

    if (callback_count == 0) {
        return;
    }

    const external_event = ExternalEvent{
        .id = event.id,
        .timestamp = event.timestamp,
        .event_type = fromBusEventType(event.event_type),
        .topic = event.topic,
        .model_type = event.model_type,
        .model_id = event.model_id,
        .data = event.data,
    };

    for (callbacks[0..callback_count]) |callback| {
        callback(&external_event);
    }
}

fn topicMatches(subscription_topic: []const u8, event_topic: []const u8) bool {
    if (std.mem.eql(u8, subscription_topic, event_topic)) {
        return true;
    }

    if (std.mem.endsWith(u8, subscription_topic, ".*")) {
        const prefix = subscription_topic[0 .. subscription_topic.len - 2];
        return event_topic.len > prefix.len and
            std.mem.startsWith(u8, event_topic, prefix) and
            event_topic[prefix.len] == '.';
    }

    return false;
}

fn toBusEventType(event_type: ExternalEventType) message_bus_mod.EventType {
    return switch (event_type) {
        .model_created => .model_created,
        .model_updated => .model_updated,
        .model_deleted => .model_deleted,
        .custom => .custom,
    };
}

fn fromBusEventType(event_type: message_bus_mod.EventType) ExternalEventType {
    return switch (event_type) {
        .model_created => .model_created,
        .model_updated => .model_updated,
        .model_deleted => .model_deleted,
        .custom => .custom,
    };
}
