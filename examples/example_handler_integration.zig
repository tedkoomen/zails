/// Complete Example: Example Handler with Message Bus Integration
///
/// This example demonstrates:
/// 1. Initializing message bus
/// 2. Creating a handler with message bus context
/// 3. Subscribing to model events
/// 4. Processing requests that publish events
/// 5. Handlers reacting to events in real-time

const std = @import("std");
const message_bus = @import("../src/message_bus/mod.zig");
const ReactiveModelWithHandlers = @import("../src/experimental/model_handler_integration.zig").ReactiveModelWithHandlers;
const example_handler = @import("../handlers/example_handler.zig");

// ============================================================================
// Define Trade Model with Handlers
// ============================================================================

fn onTradeCreated(model_data: []const u8, allocator: std.mem.Allocator) void {
    _ = allocator;
    std.log.info("🎉 Model Event: Trade created - {s}", .{model_data});
}

fn onTradeUpdated(model_data: []const u8, allocator: std.mem.Allocator) void {
    _ = allocator;
    std.log.info("📝 Model Event: Trade updated - {s}", .{model_data});
}

const Trade = ReactiveModelWithHandlers("Trade", .{
    .symbol = .String,
    .price = .i64,
    .quantity = .i64,
}, .{
    .onCreate = onTradeCreated,
    .onUpdate = onTradeUpdated,
});

// ============================================================================
// Additional Event Handlers
// ============================================================================

/// Portfolio handler - listens to trade events and updates portfolio
fn onTradeExecuted(event: *const message_bus.Event, allocator: std.mem.Allocator) void {
    _ = allocator;

    std.log.info("💼 Portfolio: Processing trade execution - {s}", .{event.data});

    // In real implementation:
    // - Parse trade data
    // - Update portfolio positions
    // - Recalculate P&L
    // - Check margin requirements
}

/// Risk management handler - monitors high-value trades
fn onRiskCheck(event: *const message_bus.Event, allocator: std.mem.Allocator) void {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        event.data,
        .{},
    ) catch return;
    defer parsed.deinit();

    const price = parsed.value.object.get("price").?.integer;
    const quantity = parsed.value.object.get("quantity").?.integer;
    const value = price * quantity;

    if (value > 1000000) {
        std.log.warn("⚠️  Risk Alert: Large position detected (${d})", .{value});
    }
}

/// Audit logger - logs all trade activity
fn onAuditLog(event: *const message_bus.Event, allocator: std.mem.Allocator) void {
    _ = allocator;
    std.log.info("📋 Audit: {s} event at {d} - {s}", .{
        event.topic,
        event.timestamp,
        event.data,
    });
}

// ============================================================================
// Main Application
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("\n" ++ "=" ** 60, .{});
    std.log.info("Example Handler with Message Bus Integration", .{});
    std.log.info("=" ** 60 ++ "\n", .{});

    // ========================================
    // 1. Initialize Message Bus
    // ========================================
    std.log.info("Step 1: Initialize message bus...\n", .{});

    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 1024,
        .worker_count = 4,
        .flush_interval_ms = 50,
    });
    defer bus.deinit();

    try bus.start();
    std.log.info("✓ Message bus started with 4 workers\n", .{});

    // ========================================
    // 2. Register Model Handlers
    // ========================================
    std.log.info("Step 2: Register model handlers...\n", .{});

    try Trade.registerHandlers(&bus, allocator);
    std.log.info("✓ Trade model handlers registered\n", .{});

    // ========================================
    // 3. Initialize Example Handler Context
    // ========================================
    std.log.info("Step 3: Initialize trade handler...\n", .{});

    var handler_context = example_handler.Context.init(allocator, &bus);
    defer handler_context.deinit();

    // Subscribe to model events
    try handler_context.subscribe();
    std.log.info("✓ Trade handler subscribed to events\n", .{});

    // ========================================
    // 4. Subscribe Additional Handlers
    // ========================================
    std.log.info("Step 4: Subscribe additional business logic...\n", .{});

    const no_filter = message_bus.Filter{ .conditions = &.{} };

    // Portfolio handler - listens to trade execution
    _ = try bus.subscribe("Trade.executed", no_filter, onTradeExecuted);

    // Risk handler - monitors all trade creations
    _ = try bus.subscribe("Trade.created", no_filter, onRiskCheck);

    // Audit handler - logs everything
    _ = try bus.subscribe("Trade.*", no_filter, onAuditLog);

    std.log.info("✓ Subscribed: Portfolio, Risk, Audit handlers\n", .{});

    // ========================================
    // 5. Create Trade Model Instance
    // ========================================
    std.log.info("Step 5: Create trade model...\n", .{});

    var trade = Trade.init(allocator);
    defer trade.deinit();
    trade.base.id = 42;

    std.log.info("✓ Trade model created (ID: {d})\n", .{trade.base.id});

    // ========================================
    // 6. Process Trade via Handler
    // ========================================
    std.log.info("Step 6: Process trade request via handler...\n", .{});

    const request1 = "{\"symbol\":\"AAPL\",\"price\":15000,\"quantity\":100}";
    var response_buffer: [4096]u8 = undefined;

    const response1 = example_handler.handle(
        &handler_context,
        request1,
        &response_buffer,
        allocator,
    );

    std.log.info("Handler response: {s}\n", .{response1.ok});

    // ========================================
    // 7. Update Trade Model (Triggers Events)
    // ========================================
    std.log.info("Step 7: Update trade model directly...\n", .{});

    try trade.base.setSymbol("AAPL", &bus);
    try trade.base.setPrice(15000, &bus);
    try trade.base.setQuantity(100, &bus);

    std.log.info("✓ Trade updated (triggers Trade.updated events)\n", .{});

    // ========================================
    // 8. Process High-Value Trade
    // ========================================
    std.log.info("Step 8: Process high-value trade...\n", .{});

    const request2 = "{\"symbol\":\"TSLA\",\"price\":250000,\"quantity\":50}";
    const response2 = example_handler.handle(
        &handler_context,
        request2,
        &response_buffer,
        allocator,
    );

    std.log.info("Handler response: {s}\n", .{response2.ok});

    // ========================================
    // 9. Wait for Async Event Processing
    // ========================================
    std.log.info("Step 9: Wait for event delivery...\n", .{});

    std.Thread.sleep(300 * std.time.ns_per_ms);

    // ========================================
    // 10. Show Statistics
    // ========================================
    std.log.info("\n" ++ "=" ** 60, .{});
    std.log.info("Final Statistics", .{});
    std.log.info("=" ** 60, .{});

    const stats = bus.getStats();
    std.log.info("Message Bus:", .{});
    std.log.info("  Published:  {d} events", .{stats.published});
    std.log.info("  Delivered:  {d} events", .{stats.delivered});
    std.log.info("  Dropped:    {d} events", .{stats.dropped});
    std.log.info("  Queued:     {d} events", .{stats.queued});

    std.log.info("\nExample Handler:", .{});
    std.log.info("  Trades processed:   {d}", .{handler_context.trades_processed.load(.acquire)});
    std.log.info("  High-value trades:  {d}", .{handler_context.high_value_trades.load(.acquire)});
    std.log.info("  Total volume:       ${d}", .{handler_context.total_volume.load(.acquire)});

    std.log.info("\nTrade Model:", .{});
    std.log.info("  Symbol:    {s}", .{trade.base.getSymbol()});
    std.log.info("  Price:     ${d}", .{trade.base.getPrice()});
    std.log.info("  Quantity:  {d}", .{trade.base.getQuantity()});
    std.log.info("  Version:   {d}", .{trade.base.getVersion()});

    std.log.info("\n" ++ "=" ** 60, .{});
    std.log.info("✅ Example completed successfully!", .{});
    std.log.info("=" ** 60 ++ "\n", .{});
}
