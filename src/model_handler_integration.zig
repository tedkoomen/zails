/// Integrated Handler System for Reactive Models
///
/// Automatically creates and registers handlers for model events.
/// When you define a model, it automatically gets:
/// - onCreate handler
/// - onUpdate handler
/// - onDelete handler
/// - Handler registry
///
/// Example:
///   const Trade = ReactiveModelWithHandlers("trades", .{
///       .symbol = .String,
///       .price = .i64,
///   }, .{
///       .onCreate = myOnCreateHandler,
///       .onUpdate = myOnUpdateHandler,
///   });

const std = @import("std");
const Allocator = std.mem.Allocator;
const ReactiveModel = @import("reactive_model.zig").ReactiveModel;
const message_bus = @import("message_bus/mod.zig");
const topic_matcher = @import("message_bus/topic_matcher.zig");
const model_topics = @import("message_bus/model_topics.zig");
const Event = @import("event.zig").Event;
const TopicId = topic_matcher.TopicId;
const Topic = topic_matcher.Topic;
const EventKind = topic_matcher.EventKind;

/// Handler function type for model events
pub const ModelHandlerFn = *const fn (model_data: []const u8, allocator: Allocator) void;

/// Handler configuration for a model
pub const HandlerConfig = struct {
    onCreate: ?ModelHandlerFn = null,
    onUpdate: ?ModelHandlerFn = null,
    onDelete: ?ModelHandlerFn = null,
};

/// Create a wrapper for a model handler (comptime)
fn createHandlerWrapper(comptime handler_fn: ModelHandlerFn) message_bus.HandlerFn {
    const Wrapper = struct {
        fn wrapper(event: *const Event, alloc: Allocator) void {
            handler_fn(event.data, alloc);
        }
    };
    return Wrapper.wrapper;
}

/// Reactive model with integrated handlers
pub fn ReactiveModelWithHandlers(
    comptime model_name: []const u8,
    comptime fields: anytype,
    comptime handlers: HandlerConfig,
) type {
    const BaseModel = ReactiveModel(model_name, fields);

    return struct {
        const Self = @This();

        // Embed base model
        base: BaseModel,

        // Handler configuration (comptime)
        pub const Handlers = handlers;

        /// Initialize model
        pub fn init(allocator: Allocator) Self {
            return Self{
                .base = BaseModel.init(allocator),
            };
        }

        /// Deinitialize model
        pub fn deinit(self: *Self) void {
            self.base.deinit();
        }

        /// Get version number
        pub fn getVersion(self: *const Self) u64 {
            return self.base.getVersion();
        }

        /// Serialize to JSON
        pub fn toJSON(self: *Self, buffer: []u8) ![]const u8 {
            return self.base.toJSON(buffer);
        }

        // Field accessors must be defined per model
        // (can't be generic due to field-specific methods like getSymbol, setPrice, etc.)

        /// Register handlers with message bus
        pub fn registerHandlers(bus: *message_bus.MessageBus, allocator: Allocator) !void {
            _ = allocator;
            const filter = message_bus.Filter{ .conditions = &.{} };

            // Register onCreate handler
            if (comptime Handlers.onCreate) |handler| {
                const topic = comptime model_name ++ ".created";
                const wrapper = comptime createHandlerWrapper(handler);
                _ = try bus.subscribe(topic, filter, wrapper);
                std.log.info("Registered onCreate handler for {s}", .{model_name});
            }

            // Register onUpdate handler
            if (comptime Handlers.onUpdate) |handler| {
                const topic = comptime model_name ++ ".updated";
                const wrapper = comptime createHandlerWrapper(handler);
                _ = try bus.subscribe(topic, filter, wrapper);
                std.log.info("Registered onUpdate handler for {s}", .{model_name});
            }

            // Register onDelete handler
            if (comptime Handlers.onDelete) |handler| {
                const topic = comptime model_name ++ ".deleted";
                const wrapper = comptime createHandlerWrapper(handler);
                _ = try bus.subscribe(topic, filter, wrapper);
                std.log.info("Registered onDelete handler for {s}", .{model_name});
            }
        }

        /// Topic constants for this model (comptime)
        pub const Topics = struct {
            // Hash-based IDs (for TopicPattern matching)
            pub const created_id = Topic(model_name, .created);
            pub const updated_id = Topic(model_name, .updated);
            pub const deleted_id = Topic(model_name, .deleted);
            pub const wildcard_id = topic_matcher.TopicWildcard(model_name);

            // String topics (for message bus subscribe/publish)
            pub const created = model_topics.ModelTopics(model_name).created;
            pub const updated = model_topics.ModelTopics(model_name).updated;
            pub const deleted = model_topics.ModelTopics(model_name).deleted;
            pub const wildcard = model_topics.ModelTopics(model_name).wildcard;
        };
    };
}

// ============================================================================
// Example Usage
// ============================================================================

// Define handlers
fn onTradeCreated(model_data: []const u8, allocator: Allocator) void {
    _ = allocator;
    std.log.info("Trade created: {s}", .{model_data});
}

fn onTradeUpdated(model_data: []const u8, allocator: Allocator) void {
    _ = allocator;
    std.log.info("Trade updated: {s}", .{model_data});
}

fn onTradeDeleted(model_data: []const u8, allocator: Allocator) void {
    _ = allocator;
    std.log.info("Trade deleted: {s}", .{model_data});
}

// Define model with integrated handlers
const Trade = ReactiveModelWithHandlers("Trade", .{
    .symbol = .String,
    .price = .i64,
    .quantity = .i64,
}, .{
    .onCreate = onTradeCreated,
    .onUpdate = onTradeUpdated,
    .onDelete = onTradeDeleted,
});

// Usage example
pub fn example() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize message bus
    var bus = try message_bus.MessageBus.init(allocator, .{});
    defer bus.deinit();
    try bus.start();

    // Register handlers (automatic!)
    try Trade.registerHandlers(&bus, allocator);

    // Create model instance
    var trade = Trade.init(allocator);
    defer trade.deinit();
    trade.base.id = 1;

    // Updates automatically trigger handlers
    try trade.base.setSymbol("AAPL", &bus);
    try trade.base.setPrice(15000, &bus);
    try trade.base.setQuantity(100, &bus);

    // Wait for delivery
    std.Thread.sleep(200 * std.time.ns_per_ms);

    std.log.info("Trade version: {d}", .{trade.getVersion()});
}

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

    // Register handlers
    try Trade.registerHandlers(&bus, allocator);

    // Create model
    var trade = Trade.init(allocator);
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
