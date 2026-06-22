/// Integrated Handler System for Reactive Models
///
/// Automatically creates and registers handlers for model events.
/// When you define a model, it automatically gets:
/// - onCreate handler
/// - onUpdate handler
/// - onDelete handler
///
/// Handlers are domain-agnostic — they receive model data and an allocator,
/// and simply call model setters. The feedback loop prevention is automatic
/// (the event worker thread-local tags outgoing events so the originating
/// handler is skipped on delivery).
///
/// Example:
///
///   const Trade = struct {
///       base: ReactiveModel("Trade", .{ .symbol = .String, .price = .i64 }),
///
///       pub fn setPrice(self: *Trade, value: i64) !void {
///           try self.base.set("price", value);
///       }
///   };
///
///   // Register handlers — they're just functions, no bus/context plumbing:
///   fn onTradeUpdated(data: []const u8, allocator: Allocator) void {
///       // pure domain logic here
///   }

const std = @import("std");
const Allocator = std.mem.Allocator;
const ReactiveModel = @import("reactive_model.zig").ReactiveModel;
const message_bus = @import("../message_bus/mod.zig");
const topic_matcher = @import("../message_bus/topic_matcher.zig");
const model_topics = @import("../message_bus/model_topics.zig");
const Event = @import("../event.zig").Event;
const TopicId = topic_matcher.TopicId;
const Topic = topic_matcher.Topic;
const EventKind = topic_matcher.EventKind;

/// Handler function type for model events.
/// Receives serialized model data and an allocator — pure domain logic.
/// No bus, no subscription IDs, no event plumbing visible to the handler.
pub const ModelHandlerFn = *const fn (model_data: []const u8, allocator: Allocator) void;

/// Handler configuration for a model.
pub const HandlerConfig = struct {
    onCreate: ?ModelHandlerFn = null,
    onUpdate: ?ModelHandlerFn = null,
    onDelete: ?ModelHandlerFn = null,
};

/// Create a wrapper that adapts a ModelHandlerFn to the bus HandlerFn signature.
fn createHandlerWrapper(comptime handler_fn: ModelHandlerFn) message_bus.HandlerFn {
    const Wrapper = struct {
        fn wrapper(event: *const Event, alloc: Allocator) void {
            handler_fn(event.data, alloc);
        }
    };
    return Wrapper.wrapper;
}

/// Reactive model with integrated handlers.
///
/// This provides the registration glue between a ReactiveModel and the
/// message bus. Domain models compose this to get automatic handler
/// registration on the correct topics.
pub fn ReactiveModelWithHandlers(
    comptime model_name: []const u8,
    comptime fields: anytype,
    comptime handlers: HandlerConfig,
) type {
    const BaseModel = ReactiveModel(model_name, fields);

    return struct {
        const Self = @This();

        /// The underlying reactive model.
        base: BaseModel,

        /// Handler configuration (comptime).
        pub const Handlers = handlers;

        /// Initialize model.
        pub fn init(allocator: Allocator, bus: ?*message_bus.MessageBus) Self {
            return Self{
                .base = BaseModel.init(allocator, bus),
            };
        }

        /// Deinitialize model.
        pub fn deinit(self: *Self) void {
            self.base.deinit();
        }

        /// Get version number.
        pub fn getVersion(self: *const Self) u64 {
            return self.base.getVersion();
        }

        /// Register handlers with message bus.
        /// Called once at startup. After this, any mutation on any instance
        /// of this model type will trigger the appropriate handler — and
        /// the handler that caused the mutation is automatically excluded
        /// from receiving its own event.
        pub fn registerHandlers(bus: *message_bus.MessageBus, allocator: Allocator) !void {
            _ = allocator;
            const filter = message_bus.Filter{ .conditions = &.{} };

            if (comptime Handlers.onCreate) |handler| {
                const topic = comptime model_name ++ ".created";
                const wrapper = comptime createHandlerWrapper(handler);
                _ = try bus.subscribe(topic, filter, wrapper);
                std.log.info("Registered onCreate handler for {s}", .{model_name});
            }

            if (comptime Handlers.onUpdate) |handler| {
                const topic = comptime model_name ++ ".updated";
                const wrapper = comptime createHandlerWrapper(handler);
                _ = try bus.subscribe(topic, filter, wrapper);
                std.log.info("Registered onUpdate handler for {s}", .{model_name});
            }

            if (comptime Handlers.onDelete) |handler| {
                const topic = comptime model_name ++ ".deleted";
                const wrapper = comptime createHandlerWrapper(handler);
                _ = try bus.subscribe(topic, filter, wrapper);
                std.log.info("Registered onDelete handler for {s}", .{model_name});
            }
        }

        /// Topic constants for this model (comptime).
        pub const Topics = struct {
            pub const created_id = Topic(model_name, .created);
            pub const updated_id = Topic(model_name, .updated);
            pub const deleted_id = Topic(model_name, .deleted);
            pub const wildcard_id = topic_matcher.TopicWildcard(model_name);

            pub const created = model_topics.ModelTopics(model_name).created;
            pub const updated = model_topics.ModelTopics(model_name).updated;
            pub const deleted = model_topics.ModelTopics(model_name).deleted;
            pub const wildcard = model_topics.ModelTopics(model_name).wildcard;
        };
    };
}

// ============================================================================
// Example: Trade domain model
// ============================================================================

fn onTradeCreated(model_data: []const u8, allocator: Allocator) void {
    _ = allocator;
    std.log.info("Trade created: {s}", .{model_data});
}

fn onTradeUpdated(model_data: []const u8, allocator: Allocator) void {
    _ = allocator;
    // Pure domain logic — no bus or subscription awareness needed.
    // If this handler mutates a Trade, the resulting event will NOT
    // be delivered back here (automatic feedback loop prevention).
    std.log.info("Trade updated: {s}", .{model_data});
}

fn onTradeDeleted(model_data: []const u8, allocator: Allocator) void {
    _ = allocator;
    std.log.info("Trade deleted: {s}", .{model_data});
}

const Trade = ReactiveModelWithHandlers("Trade", .{
    .symbol = .String,
    .price = .i64,
    .quantity = .i64,
}, .{
    .onCreate = onTradeCreated,
    .onUpdate = onTradeUpdated,
    .onDelete = onTradeDeleted,
});

// ============================================================================
// Tests
// ============================================================================

test "model with integrated handlers" {
    const allocator = std.testing.allocator;

    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1,
    });
    defer bus.deinit();

    try Trade.registerHandlers(&bus, allocator);

    var trade = Trade.init(allocator, null);
    defer trade.deinit();

    try std.testing.expectEqual(@as(u64, 1), trade.getVersion());
}

test "topic ids are unique per model" {
    const trade_created = Trade.Topics.created_id;
    const trade_updated = Trade.Topics.updated_id;

    try std.testing.expect(trade_created != trade_updated);
}

test "wildcard topic matches all events" {
    const trade_wildcard = Trade.Topics.wildcard_id;
    const trade_created = Trade.Topics.created_id;
    const trade_updated = Trade.Topics.updated_id;

    const pattern = topic_matcher.TopicPattern{ .wildcard = trade_wildcard };

    try std.testing.expect(pattern.matches(trade_created));
    try std.testing.expect(pattern.matches(trade_updated));
}

test "string topics match expected format" {
    try std.testing.expectEqualStrings("Trade.created", Trade.Topics.created);
    try std.testing.expectEqualStrings("Trade.updated", Trade.Topics.updated);
    try std.testing.expectEqualStrings("Trade.deleted", Trade.Topics.deleted);
    try std.testing.expectEqualStrings("Trade.*", Trade.Topics.wildcard);
}
