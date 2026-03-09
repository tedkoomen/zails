/// Complete Example: Handler Chain Reaction via Message Bus
///
/// This demonstrates:
/// 1. Handler A receives HTTP/gRPC request
/// 2. Handler A updates a model
/// 3. Model publishes event to message bus
/// 4. Handler B (subscribed to that event) is triggered
/// 5. Handler B updates another model
/// 6. Handler C (subscribed to that event) is triggered
/// 7. Complete chain reaction via message bus

const std = @import("std");
const message_bus = @import("../src/message_bus/mod.zig");
const Event = @import("../src/event.zig").Event;
const ReactiveModelWithHandlers = @import("../src/experimental/model_handler_integration.zig").ReactiveModelWithHandlers;

// ============================================================================
// Step 1: Define Models with Event Publishing
// ============================================================================

const Trade = ReactiveModelWithHandlers("Trade", .{
    .symbol = .String,
    .price = .i64,
    .quantity = .i64,
}, .{});

const Portfolio = ReactiveModelWithHandlers("Portfolio", .{
    .user_id = .u64,
    .cash_balance = .i64,
}, .{});

const RiskAlert = ReactiveModelWithHandlers("RiskAlert", .{
    .severity = .i64,
    .message = .String,
}, .{});

// ============================================================================
// Step 2: Define Handler A - Trade Executor (receives requests)
// ============================================================================

var trade_model: ?*Trade = null; // Global reference for example

fn onTradeRequest(event: *const Event, allocator: std.mem.Allocator) void {
    _ = allocator;

    std.log.info("\n[HANDLER A] 📨 Trade request received", .{});
    std.log.info("[HANDLER A]    Event: {s}", .{event.data});

    // Parse request (simplified for example)
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        event.data,
        .{},
    ) catch return;
    defer parsed.deinit();

    const symbol = parsed.value.object.get("symbol").?.string;
    const price = parsed.value.object.get("price").?.integer;
    const quantity = parsed.value.object.get("quantity").?.integer;

    std.log.info("[HANDLER A]    Executing trade: {s} @ ${d} x {d}", .{
        symbol,
        price,
        quantity,
    });

    // Update trade model (THIS TRIGGERS THE CHAIN!)
    if (trade_model) |trade| {
        const globals = @import("../src/globals.zig");
        const bus = globals.global_message_bus;

        trade.base.setSymbol(symbol, bus) catch {};
        trade.base.setPrice(price, bus) catch {};
        trade.base.setQuantity(quantity, bus) catch {};

        std.log.info("[HANDLER A] ✓ Trade model updated → publishes Trade.updated event", .{});
    }
}

// ============================================================================
// Step 3: Define Handler B - Portfolio Manager (triggered by Trade.updated)
// ============================================================================

var portfolio_model: ?*Portfolio = null; // Global reference for example

fn onTradeUpdated(event: *const Event, allocator: std.mem.Allocator) void {
    _ = allocator;

    std.log.info("\n[HANDLER B] 🔔 Trade.updated event received", .{});
    std.log.info("[HANDLER B]    Event data: {s}", .{event.data});

    // Parse trade data
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        event.data,
        .{},
    ) catch return;
    defer parsed.deinit();

    const price = parsed.value.object.get("price").?.integer;
    const quantity = parsed.value.object.get("quantity").?.integer;
    const trade_value = price * quantity;

    std.log.info("[HANDLER B]    Calculated trade value: ${d}", .{trade_value});
    std.log.info("[HANDLER B]    Updating portfolio...", .{});

    // Update portfolio (THIS TRIGGERS ANOTHER EVENT!)
    if (portfolio_model) |portfolio| {
        const globals = @import("../src/globals.zig");
        const bus = globals.global_message_bus;

        const current_balance = portfolio.base.getCashBalance();
        const new_balance = current_balance - trade_value;

        portfolio.base.setCashBalance(new_balance, bus) catch {};

        std.log.info("[HANDLER B] ✓ Portfolio updated: ${d} → ${d}", .{
            current_balance,
            new_balance,
        });
        std.log.info("[HANDLER B] ✓ Publishes Portfolio.updated event", .{});
    }
}

// ============================================================================
// Step 4: Define Handler C - Risk Manager (triggered by Portfolio.updated)
// ============================================================================

var risk_alert_model: ?*RiskAlert = null; // Global reference for example

fn onPortfolioUpdated(event: *const Event, allocator: std.mem.Allocator) void {
    _ = allocator;

    std.log.info("\n[HANDLER C] 🔔 Portfolio.updated event received", .{});
    std.log.info("[HANDLER C]    Event data: {s}", .{event.data});

    // Parse portfolio data
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        event.data,
        .{},
    ) catch return;
    defer parsed.deinit();

    const balance = parsed.value.object.get("cash_balance").?.integer;

    std.log.info("[HANDLER C]    Cash balance: ${d}", .{balance});

    // Check for low balance
    if (balance < 10000) {
        std.log.warn("[HANDLER C] ⚠️  LOW BALANCE ALERT!", .{});
        std.log.info("[HANDLER C]    Creating risk alert...", .{});

        // Update risk alert model (ANOTHER EVENT!)
        if (risk_alert_model) |alert| {
            const globals = @import("../src/globals.zig");
            const bus = globals.global_message_bus;

            alert.base.setSeverity(2, bus) catch {}; // High severity

            const msg = "Low cash balance detected";
            alert.base.setMessage(msg, bus) catch {};

            std.log.info("[HANDLER C] ✓ Risk alert created → publishes RiskAlert.updated event", .{});
        }
    } else {
        std.log.info("[HANDLER C] ✓ Balance OK, no alert needed", .{});
    }
}

// ============================================================================
// Step 5: Define Handler D - Alert Logger (triggered by RiskAlert.updated)
// ============================================================================

fn onRiskAlertUpdated(event: *const Event, allocator: std.mem.Allocator) void {
    _ = allocator;

    std.log.info("\n[HANDLER D] 🔔 RiskAlert.updated event received", .{});
    std.log.info("[HANDLER D]    Event data: {s}", .{event.data});

    // Parse alert data
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        event.data,
        .{},
    ) catch return;
    defer parsed.deinit();

    const severity = parsed.value.object.get("severity").?.integer;
    const message = parsed.value.object.get("message").?.string;

    std.log.err("[HANDLER D] 🚨 CRITICAL ALERT - Severity {d}: {s}", .{
        severity,
        message,
    });

    std.log.info("[HANDLER D] ✓ Alert logged to database", .{});
    std.log.info("[HANDLER D] ✓ Notification sent to admin", .{});
}

// ============================================================================
// Main: Setup and Demonstration
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("\n" ++ "=" ** 70, .{});
    std.log.info("Handler Chain Reaction Demo - Message Bus Integration", .{});
    std.log.info("=" ** 70 ++ "\n", .{});

    // ========================================
    // 1. Initialize Message Bus
    // ========================================
    std.log.info("Step 1: Initialize message bus...\n", .{});

    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 1024,
        .worker_count = 4,
    });
    defer bus.deinit();
    try bus.start();

    // Set global for handlers to access
    var globals = @import("../src/globals.zig");
    globals.global_message_bus = &bus;

    std.log.info("✓ Message bus started with 4 workers\n", .{});

    // ========================================
    // 2. Subscribe Handlers to Events
    // ========================================
    std.log.info("Step 2: Subscribe handlers to events...\n", .{});

    const filter = message_bus.Filter{ .conditions = &.{} };

    // Handler A: Listens to trade requests
    _ = try bus.subscribe("Trade.request", filter, onTradeRequest);
    std.log.info("✓ Handler A subscribed to: Trade.request", .{});

    // Handler B: Listens to trade updates
    _ = try bus.subscribe("Trade.updated", filter, onTradeUpdated);
    std.log.info("✓ Handler B subscribed to: Trade.updated", .{});

    // Handler C: Listens to portfolio updates
    _ = try bus.subscribe("Portfolio.updated", filter, onPortfolioUpdated);
    std.log.info("✓ Handler C subscribed to: Portfolio.updated", .{});

    // Handler D: Listens to risk alerts
    _ = try bus.subscribe("RiskAlert.updated", filter, onRiskAlertUpdated);
    std.log.info("✓ Handler D subscribed to: RiskAlert.updated\n", .{});

    // ========================================
    // 3. Create Models
    // ========================================
    std.log.info("Step 3: Create models...\n", .{});

    var trade = Trade.init(allocator);
    defer trade.deinit();
    trade.base.id = 1;
    trade_model = &trade;

    var portfolio = Portfolio.init(allocator);
    defer portfolio.deinit();
    portfolio.base.id = 100;
    portfolio.base.setUserId(42, &bus) catch {};
    portfolio.base.setCashBalance(50000, &bus) catch {}; // Starting balance
    portfolio_model = &portfolio;

    var risk_alert = RiskAlert.init(allocator);
    defer risk_alert.deinit();
    risk_alert.base.id = 200;
    risk_alert_model = &risk_alert;

    std.log.info("✓ Models created\n", .{});

    // Wait for initial events to clear
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // ========================================
    // 4. Trigger the Chain!
    // ========================================
    std.log.info("\n" ++ "=" ** 70, .{});
    std.log.info("TRIGGERING HANDLER CHAIN", .{});
    std.log.info("=" ** 70, .{});

    // Simulate incoming trade request
    const request_data = "{\"symbol\":\"AAPL\",\"price\":15000,\"quantity\":100}";
    const request_event = Event{
        .id = @import("../src/event.zig").generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .custom,
        .topic = "Trade.request",
        .model_type = "Trade",
        .model_id = 0,
        .data = request_data,
    };

    std.log.info("\n🚀 Publishing Trade.request event...\n", .{});
    bus.publish(request_event);

    // Wait for chain reaction to complete
    std.log.info("\nWaiting for chain reaction...\n", .{});
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // ========================================
    // 5. Show Final State
    // ========================================
    std.log.info("\n" ++ "=" ** 70, .{});
    std.log.info("FINAL STATE", .{});
    std.log.info("=" ** 70, .{});

    std.log.info("\nTrade Model:", .{});
    std.log.info("  Symbol:   {s}", .{trade.base.getSymbol()});
    std.log.info("  Price:    ${d}", .{trade.base.getPrice()});
    std.log.info("  Quantity: {d}", .{trade.base.getQuantity()});
    std.log.info("  Version:  {d}", .{trade.base.getVersion()});

    std.log.info("\nPortfolio Model:", .{});
    std.log.info("  User ID:       {d}", .{portfolio.base.getUserId()});
    std.log.info("  Cash Balance:  ${d}", .{portfolio.base.getCashBalance()});
    std.log.info("  Version:       {d}", .{portfolio.base.getVersion()});

    std.log.info("\nRisk Alert Model:", .{});
    std.log.info("  Severity: {d}", .{risk_alert.base.getSeverity()});
    std.log.info("  Message:  {s}", .{risk_alert.base.getMessage()});
    std.log.info("  Version:  {d}", .{risk_alert.base.getVersion()});

    // ========================================
    // 6. Show Event Statistics
    // ========================================
    const stats = bus.getStats();

    std.log.info("\nMessage Bus Statistics:", .{});
    std.log.info("  Events Published: {d}", .{stats.published});
    std.log.info("  Events Delivered: {d}", .{stats.delivered});
    std.log.info("  Events Dropped:   {d}", .{stats.dropped});
    std.log.info("  Events Queued:    {d}", .{stats.queued});

    std.log.info("\n" ++ "=" ** 70, .{});
    std.log.info("✅ Handler chain completed successfully!", .{});
    std.log.info("=" ** 70 ++ "\n", .{});

    // ========================================
    // 7. Demonstrate Second Chain (Large Trade)
    // ========================================
    std.log.info("\n" ++ "=" ** 70, .{});
    std.log.info("SECOND CHAIN: Large Trade (triggers low balance alert)", .{});
    std.log.info("=" ** 70, .{});

    const large_request = "{\"symbol\":\"TSLA\",\"price\":25000,\"quantity\":10}";
    const large_event = Event{
        .id = @import("../src/event.zig").generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .custom,
        .topic = "Trade.request",
        .model_type = "Trade",
        .model_id = 0,
        .data = large_request,
    };

    std.log.info("\n🚀 Publishing large Trade.request event...\n", .{});
    bus.publish(large_event);

    std.Thread.sleep(500 * std.time.ns_per_ms);

    std.log.info("\n" ++ "=" ** 70, .{});
    std.log.info("✅ Second chain completed!", .{});
    std.log.info("=" ** 70 ++ "\n", .{});
}
