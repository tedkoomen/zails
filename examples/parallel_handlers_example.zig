/// Example: Parallel Handler Execution
///
/// This example demonstrates how multiple handlers for the same event
/// execute in parallel.

const std = @import("std");
const ReactiveModelWithHandlers = @import("../src/experimental/model_handler_integration.zig").ReactiveModelWithHandlers;
const message_bus = @import("../src/message_bus/mod.zig");

// Simulate slow handlers
var handler1_start: i64 = 0;
var handler2_start: i64 = 0;
var handler3_start: i64 = 0;
var handler1_end: i64 = 0;
var handler2_end: i64 = 0;
var handler3_end: i64 = 0;

fn slowHandler1(model_data: []const u8, allocator: std.mem.Allocator) void {
    _ = allocator;

    handler1_start = std.time.milliTimestamp();
    std.log.info("Handler 1 started - processing: {s}", .{model_data});

    // Simulate work
    std.Thread.sleep(100 * std.time.ns_per_ms);

    handler1_end = std.time.milliTimestamp();
    std.log.info("Handler 1 finished (took {}ms)", .{handler1_end - handler1_start});
}

fn slowHandler2(model_data: []const u8, allocator: std.mem.Allocator) void {
    _ = allocator;

    handler2_start = std.time.milliTimestamp();
    std.log.info("Handler 2 started - processing: {s}", .{model_data});

    // Simulate work
    std.Thread.sleep(100 * std.time.ns_per_ms);

    handler2_end = std.time.milliTimestamp();
    std.log.info("Handler 2 finished (took {}ms)", .{handler2_end - handler2_start});
}

fn slowHandler3(model_data: []const u8, allocator: std.mem.Allocator) void {
    _ = allocator;

    handler3_start = std.time.milliTimestamp();
    std.log.info("Handler 3 started - processing: {s}", .{model_data});

    // Simulate work
    std.Thread.sleep(100 * std.time.ns_per_ms);

    handler3_end = std.time.milliTimestamp();
    std.log.info("Handler 3 finished (took {}ms)", .{handler3_end - handler3_start});
}

// Define model with NO handlers (we'll subscribe manually)
const Trade = ReactiveModelWithHandlers("Trade", .{
    .symbol = .String,
    .price = .i64,
    .quantity = .i64,
}, .{});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Parallel Handler Execution Demo ===\n", .{});

    // ========================================
    // 1. Initialize message bus
    // ========================================
    var bus = try message_bus.MessageBus.init(allocator, .{
        .worker_count = 1, // Single worker to demonstrate parallel handlers
    });
    defer bus.deinit();
    try bus.start();

    // ========================================
    // 2. Subscribe 3 slow handlers to same event
    // ========================================
    const filter = message_bus.Filter{ .conditions = &.{} };

    _ = try bus.subscribe("Trade.updated", filter, slowHandler1);
    _ = try bus.subscribe("Trade.updated", filter, slowHandler2);
    _ = try bus.subscribe("Trade.updated", filter, slowHandler3);

    std.log.info("Subscribed 3 handlers (each takes 100ms)\n", .{});

    // ========================================
    // 3. Create and update model
    // ========================================
    var trade = Trade.init(allocator);
    defer trade.deinit();
    trade.base.id = 1;

    std.log.info("Updating trade...\n", .{});
    const event_start = std.time.milliTimestamp();

    try trade.base.setPrice(15000, &bus);

    const publish_latency = std.time.milliTimestamp() - event_start;
    std.log.info("Published event (latency: {}ms)\n", .{publish_latency});

    // ========================================
    // 4. Wait for handlers to complete
    // ========================================
    std.log.info("Waiting for handlers...\n", .{});
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // ========================================
    // 5. Analyze results
    // ========================================
    std.log.info("\n=== Results ===\n", .{});

    const total_time = @max(handler1_end, @max(handler2_end, handler3_end)) -
                       @min(handler1_start, @min(handler2_start, handler3_start));

    std.log.info("Handler 1: {}ms to {}ms", .{handler1_start, handler1_end});
    std.log.info("Handler 2: {}ms to {}ms", .{handler2_start, handler2_end});
    std.log.info("Handler 3: {}ms to {}ms", .{handler3_start, handler3_end});
    std.log.info("\nTotal time: {}ms", .{total_time});

    // Calculate overlap
    const max_start = @max(handler1_start, @max(handler2_start, handler3_start));
    const min_end = @min(handler1_end, @min(handler2_end, handler3_end));
    const overlap = if (min_end > max_start) min_end - max_start else 0;

    std.log.info("Overlap period: {}ms", .{overlap});

    if (total_time < 200) {
        std.log.info("\n✅ PARALLEL EXECUTION CONFIRMED!", .{});
        std.log.info("   3 handlers (100ms each) completed in ~{}ms", .{total_time});
        std.log.info("   Sequential would take 300ms+", .{});
    } else {
        std.log.warn("\n⚠️  Handlers may have run sequentially", .{});
    }

    std.log.info("\n=== Speedup Analysis ===", .{});
    const sequential_time: i64 = 300; // 3 handlers × 100ms each
    const speedup = @as(f64, @floatFromInt(sequential_time)) / @as(f64, @floatFromInt(total_time));
    std.log.info("Sequential time: {}ms", .{sequential_time});
    std.log.info("Parallel time:   {}ms", .{total_time});
    std.log.info("Speedup:         {d:.2}x", .{speedup});
}
