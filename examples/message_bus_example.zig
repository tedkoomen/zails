const std = @import("std");
const message_bus = @import("../src/message_bus/mod.zig");
const Event = @import("../src/event.zig").Event;
const generateEventId = @import("../src/event.zig").generateEventId;

/// Example: Trade subscription system using the message bus
///
/// This demonstrates:
/// 1. Publishing trade events when trades are created
/// 2. Multiple subscribers with different filters
/// 3. Reactive handlers that execute automatically
///
/// Run with: zig run examples/message_bus_example.zig

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize message bus
    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 1024,
        .worker_count = 4,
        .flush_interval_ms = 10,
    });
    defer bus.deinit();

    try bus.start();

    std.log.info("=== Message Bus Example: Trade Subscription System ===\n", .{});

    // --- Subscriber 1: All trades ---
    const AllTradesHandler = struct {
        fn handle(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            std.log.info("[ALL TRADES] Event: {s}, Model ID: {d}", .{
                event.topic,
                event.model_id,
            });
        }
    };

    const all_filter = message_bus.Filter{ .conditions = &.{} };
    const all_sub_id = try bus.subscribe("Trade.*", all_filter, AllTradesHandler.handle);
    std.log.info("✓ Subscribed to all trades (ID: {d})\n", .{all_sub_id});

    // --- Subscriber 2: High-value trades only (price > 10000) ---
    const HighValueHandler = struct {
        fn handle(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            std.log.info("[HIGH VALUE] Trade over $10,000 - Model ID: {d}", .{event.model_id});
            std.log.info("  Data: {s}", .{event.data});
        }
    };

    const high_value_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gt, .value = "10000" },
        },
    };
    const high_sub_id = try bus.subscribe("Trade.created", high_value_filter, HighValueHandler.handle);
    std.log.info("✓ Subscribed to high-value trades (ID: {d})\n", .{high_sub_id});

    // --- Subscriber 3: Specific symbol (AAPL) ---
    const AAPLHandler = struct {
        fn handle(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            std.log.info("[AAPL ONLY] Apple trade detected - Model ID: {d}", .{event.model_id});
        }
    };

    const aapl_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .eq, .value = "AAPL" },
        },
    };
    const aapl_sub_id = try bus.subscribe("Trade.created", aapl_filter, AAPLHandler.handle);
    std.log.info("✓ Subscribed to AAPL trades (ID: {d})\n", .{aapl_sub_id});

    // --- Publish some trade events ---
    std.log.info("\n--- Publishing Trade Events ---\n", .{});

    // Trade 1: Low-value TSLA (matches: all trades)
    const trade1 = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{\"symbol\":\"TSLA\",\"price\":5000,\"quantity\":10}",
    };
    bus.publish(trade1);
    std.log.info("Published: TSLA @ $5,000", .{});

    // Trade 2: High-value AAPL (matches: all trades, high value, AAPL)
    const trade2 = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 2,
        .data = "{\"symbol\":\"AAPL\",\"price\":15000,\"quantity\":100}",
    };
    bus.publish(trade2);
    std.log.info("Published: AAPL @ $15,000", .{});

    // Trade 3: High-value GOOGL (matches: all trades, high value)
    const trade3 = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 3,
        .data = "{\"symbol\":\"GOOGL\",\"price\":12000,\"quantity\":50}",
    };
    bus.publish(trade3);
    std.log.info("Published: GOOGL @ $12,000", .{});

    // Trade 4: Low-value AAPL (matches: all trades, AAPL)
    const trade4 = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 4,
        .data = "{\"symbol\":\"AAPL\",\"price\":8000,\"quantity\":20}",
    };
    bus.publish(trade4);
    std.log.info("Published: AAPL @ $8,000", .{});

    // Give workers time to process events
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // --- Print statistics ---
    const stats = bus.getStats();
    std.log.info("\n--- Message Bus Statistics ---", .{});
    std.log.info("Total published: {d}", .{stats.published});
    std.log.info("Total dropped: {d}", .{stats.dropped});
    std.log.info("Total delivered: {d}", .{stats.delivered});
    std.log.info("Currently queued: {d}", .{stats.queued});

    // Unsubscribe
    bus.unsubscribe(all_sub_id);
    bus.unsubscribe(high_sub_id);
    bus.unsubscribe(aapl_sub_id);

    std.log.info("\n✓ Example completed successfully!", .{});
}
