// Message Bus Module - Event-driven reactive system
//
// This module provides a Kafka-like pub/sub message bus for the Zails framework.
// It enables reactive, event-driven architectures with:
//
// - Lock-free event publishing (< 1µs latency)
// - Parameterized topic subscriptions with filters
// - Background worker threads for async event delivery
// - Persistent audit log to ClickHouse
//
// Example usage:
//
//   const message_bus = @import("message_bus/mod.zig");
//
//   // Initialize global message bus
//   try message_bus.initGlobalMessageBus(allocator, .{});
//   defer message_bus.deinitGlobalMessageBus(allocator);
//
//   // Get bus instance
//   const bus = message_bus.getGlobalMessageBus().?;
//
//   // Subscribe to events
//   fn handleTrade(event: *const Event, allocator: Allocator) void {
//       std.log.info("Trade created: {s}", .{event.data});
//   }
//
//   const filter = message_bus.Filter{
//       .conditions = &.{
//           .{ .field = "price", .op = .gt, .value = "1000" },
//       },
//   };
//
//   const sub_id = try bus.subscribe("Trade.created", filter, handleTrade);
//   defer bus.unsubscribe(sub_id);
//
//   // Publish events
//   const event = message_bus.Event{
//       .id = message_bus.generateEventId(),
//       .timestamp = std.time.microTimestamp(),
//       .event_type = .model_created,
//       .topic = "Trade.created",
//       .model_type = "Trade",
//       .model_id = 42,
//       .data = "{\"symbol\":\"AAPL\",\"price\":15000}",
//   };
//
//   bus.publish(event);

// Core message bus
pub const MessageBus = @import("message_bus.zig").MessageBus;
pub const Event = @import("../event.zig").Event;
pub const EventType = @import("../event.zig").Event.EventType;
pub const generateEventId = @import("../event.zig").generateEventId;
pub const FieldValue = @import("../event.zig").FieldValue;
pub const Field = @import("../event.zig").Field;
pub const FixedString = @import("../event.zig").FixedString;
pub const MAX_EVENT_FIELDS = @import("../event.zig").MAX_EVENT_FIELDS;

// Filters and subscriptions
pub const Filter = @import("filter.zig").Filter;
pub const WhereClause = @import("filter.zig").Filter.WhereClause;

pub const Subscription = @import("subscriber.zig").Subscription;
pub const SubscriptionId = @import("subscriber.zig").SubscriptionId;
pub const HandlerFn = @import("subscriber.zig").HandlerFn;

// Internal components
pub const EventRingBuffer = @import("ring_buffer.zig").EventRingBuffer;
pub const SubscriberRegistry = @import("subscriber_registry.zig").SubscriberRegistry; // Legacy (uses RwLock)
pub const LockFreeSubscriberRegistry = @import("lockfree_subscriber_registry.zig").LockFreeSubscriberRegistry; // Lock-free version
pub const EventWorker = @import("event_worker.zig").EventWorker;

// Entity-owned topic declarations
pub const ModelTopics = @import("model_topics.zig").ModelTopics;
pub const FeedTopics = @import("model_topics.zig").FeedTopics;
pub const CustomTopic = @import("model_topics.zig").CustomTopic;
pub const validateTopicFormat = @import("model_topics.zig").validateTopicFormat;
pub const SystemTopics = @import("system_topics.zig").SystemTopics;

// Simplified Event API (handlers don't need to know Event internals)
pub const EventBuilder = @import("event_builder.zig").EventBuilder;
pub const publishEvent = @import("event_builder.zig").publishEvent;
pub const publishModelEvent = @import("event_builder.zig").publishModelEvent;

// Global message bus functions
pub const initGlobalMessageBus = @import("global.zig").initGlobalMessageBus;
pub const getGlobalMessageBus = @import("global.zig").getGlobalMessageBus;
pub const deinitGlobalMessageBus = @import("global.zig").deinitGlobalMessageBus;

test {
    // Run all tests in sub-modules
    @import("std").testing.refAllDecls(@This());
}
