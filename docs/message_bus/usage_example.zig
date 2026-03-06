// ============================================================================
// MESSAGE BUS USAGE EXAMPLES
// ============================================================================
//
// This file provides practical, copy-paste-ready examples for using the
// Message Bus in the Zails framework.
//
// ============================================================================

const std = @import("std");
const message_bus = @import("../src/message_bus/mod.zig");
const Event = @import("../src/event.zig").Event;
const generateEventId = @import("../src/event.zig").generateEventId;

// ============================================================================
// EXAMPLE 1: Basic Setup and Teardown
// ============================================================================

pub fn example1_basicSetup() !void {
    std.log.info("\n=== Example 1: Basic Setup ===\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create message bus
    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 1024, // Max events in queue
        .worker_count = 4, // Background threads
        .flush_interval_ms = 100, // Worker sleep when idle
    });
    defer bus.deinit();

    // Start background workers
    try bus.start();

    std.log.info("✓ Message bus initialized and started", .{});
}

// ============================================================================
// EXAMPLE 2: Simple Publish/Subscribe
// ============================================================================

pub fn example2_simplePublishSubscribe() !void {
    std.log.info("\n=== Example 2: Simple Publish/Subscribe ===\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bus = try message_bus.MessageBus.init(allocator, .{});
    defer bus.deinit();
    try bus.start();

    // Define handler function
    const MyHandler = struct {
        fn handle(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            std.log.info("📨 Received event: {s} (ID: {d})", .{
                event.topic,
                event.model_id,
            });
        }
    };

    // Subscribe (no filter = match all)
    const empty_filter = message_bus.Filter{ .conditions = &.{} };
    const sub_id = try bus.subscribe("Trade.created", empty_filter, MyHandler.handle);
    defer bus.unsubscribe(sub_id);

    // Publish event
    const event = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 42,
        .data = "{\"symbol\":\"AAPL\",\"price\":150}",
    };

    bus.publish(event);
    std.log.info("✓ Event published", .{});

    // Give workers time to process
    std.Thread.sleep(200 * std.time.ns_per_ms);
}

// ============================================================================
// EXAMPLE 3: Filtered Subscriptions
// ============================================================================

pub fn example3_filteredSubscriptions() !void {
    std.log.info("\n=== Example 3: Filtered Subscriptions ===\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bus = try message_bus.MessageBus.init(allocator, .{});
    defer bus.deinit();
    try bus.start();

    // Handler for high-value trades
    const HighValueHandler = struct {
        fn handle(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            std.log.info("💰 HIGH VALUE ALERT: Trade {d}", .{event.model_id});
        }
    };

    // Subscribe with filter: price > 10000
    const high_value_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gt, .value = "10000" },
        },
    };

    const sub_id = try bus.subscribe("Trade.created", high_value_filter, HighValueHandler.handle);
    defer bus.unsubscribe(sub_id);

    // Publish low-value trade (won't trigger handler)
    const low_trade = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{\"symbol\":\"TSLA\",\"price\":5000}",
    };
    bus.publish(low_trade);
    std.log.info("Published low-value trade (won't match filter)", .{});

    // Publish high-value trade (will trigger handler)
    const high_trade = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 2,
        .data = "{\"symbol\":\"AAPL\",\"price\":15000}",
    };
    bus.publish(high_trade);
    std.log.info("Published high-value trade (will match filter)", .{});

    std.Thread.sleep(200 * std.time.ns_per_ms);
}

// ============================================================================
// EXAMPLE 4: Multiple Filters (AND Logic)
// ============================================================================

pub fn example4_multipleFilters() !void {
    std.log.info("\n=== Example 4: Multiple Filters (AND Logic) ===\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bus = try message_bus.MessageBus.init(allocator, .{});
    defer bus.deinit();
    try bus.start();

    const Handler = struct {
        fn handle(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            std.log.info("🎯 Matched: AAPL with high price (ID: {d})", .{event.model_id});
        }
    };

    // Filter: symbol = "AAPL" AND price > 1000 AND quantity >= 100
    const complex_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .eq, .value = "AAPL" },
            .{ .field = "price", .op = .gt, .value = "1000" },
            .{ .field = "quantity", .op = .gte, .value = "100" },
        },
    };

    const sub_id = try bus.subscribe("Trade.created", complex_filter, Handler.handle);
    defer bus.unsubscribe(sub_id);

    // Test 1: AAPL, high price, high quantity (MATCHES)
    bus.publish(Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{\"symbol\":\"AAPL\",\"price\":1500,\"quantity\":150}",
    });

    // Test 2: AAPL, high price, low quantity (NO MATCH)
    bus.publish(Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 2,
        .data = "{\"symbol\":\"AAPL\",\"price\":1500,\"quantity\":50}",
    });

    // Test 3: TSLA, high price, high quantity (NO MATCH)
    bus.publish(Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 3,
        .data = "{\"symbol\":\"TSLA\",\"price\":2000,\"quantity\":200}",
    });

    std.Thread.sleep(200 * std.time.ns_per_ms);
}

// ============================================================================
// EXAMPLE 5: Wildcard Topics
// ============================================================================

pub fn example5_wildcardTopics() !void {
    std.log.info("\n=== Example 5: Wildcard Topics ===\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bus = try message_bus.MessageBus.init(allocator, .{});
    defer bus.deinit();
    try bus.start();

    const Handler = struct {
        fn handle(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            std.log.info("📬 Trade event: {s}", .{event.topic});
        }
    };

    // Subscribe to ALL trade events using wildcard
    const empty_filter = message_bus.Filter{ .conditions = &.{} };
    const sub_id = try bus.subscribe("Trade.*", empty_filter, Handler.handle);
    defer bus.unsubscribe(sub_id);

    // Publish different trade events
    bus.publish(Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{}",
    });

    bus.publish(Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_updated,
        .topic = "Trade.updated",
        .model_type = "Trade",
        .model_id = 2,
        .data = "{}",
    });

    bus.publish(Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_deleted,
        .topic = "Trade.deleted",
        .model_type = "Trade",
        .model_id = 3,
        .data = "{}",
    });

    // This won't match (different model)
    bus.publish(Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Portfolio.created",
        .model_type = "Portfolio",
        .model_id = 4,
        .data = "{}",
    });

    std.Thread.sleep(200 * std.time.ns_per_ms);
}

// ============================================================================
// EXAMPLE 6: Multiple Subscribers to Same Topic
// ============================================================================

pub fn example6_multipleSubscribers() !void {
    std.log.info("\n=== Example 6: Multiple Subscribers ===\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bus = try message_bus.MessageBus.init(allocator, .{});
    defer bus.deinit();
    try bus.start();

    // Handler 1: Update portfolio
    const PortfolioHandler = struct {
        fn handle(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            std.log.info("📊 Portfolio: Update for trade {d}", .{event.model_id});
        }
    };

    // Handler 2: Send risk alert
    const RiskHandler = struct {
        fn handle(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            std.log.info("⚠️  Risk: Analyze trade {d}", .{event.model_id});
        }
    };

    // Handler 3: Log metrics
    const MetricsHandler = struct {
        fn handle(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            std.log.info("📈 Metrics: Record trade {d}", .{event.model_id});
        }
    };

    const empty_filter = message_bus.Filter{ .conditions = &.{} };

    // All subscribe to same topic
    const sub1 = try bus.subscribe("Trade.created", empty_filter, PortfolioHandler.handle);
    defer bus.unsubscribe(sub1);

    const sub2 = try bus.subscribe("Trade.created", empty_filter, RiskHandler.handle);
    defer bus.unsubscribe(sub2);

    const sub3 = try bus.subscribe("Trade.created", empty_filter, MetricsHandler.handle);
    defer bus.unsubscribe(sub3);

    // One event triggers all three handlers
    bus.publish(Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 42,
        .data = "{\"symbol\":\"AAPL\",\"price\":150}",
    });

    std.Thread.sleep(200 * std.time.ns_per_ms);
}

// ============================================================================
// EXAMPLE 7: Statistics and Monitoring
// ============================================================================

pub fn example7_statistics() !void {
    std.log.info("\n=== Example 7: Statistics ===\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bus = try message_bus.MessageBus.init(allocator, .{});
    defer bus.deinit();
    try bus.start();

    // Publish multiple events
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        bus.publish(Event{
            .id = generateEventId(),
            .timestamp = std.time.microTimestamp(),
            .event_type = .model_created,
            .topic = "Trade.created",
            .model_type = "Trade",
            .model_id = i,
            .data = "{}",
        });
    }

    // Get statistics
    const stats = bus.getStats();

    std.log.info("📊 Message Bus Statistics:", .{});
    std.log.info("  - Published:  {d}", .{stats.published});
    std.log.info("  - Dropped:    {d}", .{stats.dropped});
    std.log.info("  - Delivered:  {d}", .{stats.delivered});
    std.log.info("  - Queued:     {d}", .{stats.queued});
}

// ============================================================================
// EXAMPLE 8: All Filter Operators
// ============================================================================

pub fn example8_allOperators() !void {
    std.log.info("\n=== Example 8: All Filter Operators ===\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Operator: eq (equal)
    const eq_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .eq, .value = "AAPL" },
        },
    };

    // Operator: ne (not equal)
    const ne_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "status", .op = .ne, .value = "cancelled" },
        },
    };

    // Operator: gt (greater than)
    const gt_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gt, .value = "1000" },
        },
    };

    // Operator: gte (greater than or equal)
    const gte_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "quantity", .op = .gte, .value = "100" },
        },
    };

    // Operator: lt (less than)
    const lt_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "price", .op = .lt, .value = "500" },
        },
    };

    // Operator: lte (less than or equal)
    const lte_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "quantity", .op = .lte, .value = "50" },
        },
    };

    // Operator: like (substring match)
    const like_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .like, .value = "AA" }, // Matches "AAPL"
        },
    };

    // Operator: in (set membership)
    const in_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "status", .op = .in, .value = "pending,active,completed" },
        },
    };

    // Operator: not_in (set exclusion)
    const not_in_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .not_in, .value = "MSFT,GOOGL" },
        },
    };

    std.log.info("✓ All filter operators demonstrated", .{});
    _ = eq_filter;
    _ = ne_filter;
    _ = gt_filter;
    _ = gte_filter;
    _ = lt_filter;
    _ = lte_filter;
    _ = like_filter;
    _ = in_filter;
    _ = not_in_filter;
}

// ============================================================================
// EXAMPLE 9: Real-World Trade System
// ============================================================================

pub fn example9_realWorldTradeSystem() !void {
    std.log.info("\n=== Example 9: Real-World Trade System ===\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 8192,
        .worker_count = 4,
    });
    defer bus.deinit();
    try bus.start();

    // --- Subscriber 1: Portfolio Updates ---
    const PortfolioSystem = struct {
        fn update(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            std.log.info("💼 Portfolio: Processing trade {d}", .{event.model_id});
            // Update user portfolio balance
            // Recalculate positions
        }
    };

    const portfolio_filter = message_bus.Filter{ .conditions = &.{} };
    _ = try bus.subscribe("Trade.*", portfolio_filter, PortfolioSystem.update);

    // --- Subscriber 2: Risk Management (High-Value Only) ---
    const RiskSystem = struct {
        fn analyze(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            std.log.info("⚠️  Risk: High-value trade {d} - running analysis", .{event.model_id});
            // Check exposure limits
            // Alert if threshold exceeded
        }
    };

    const risk_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gt, .value = "10000" },
        },
    };
    _ = try bus.subscribe("Trade.created", risk_filter, RiskSystem.analyze);

    // --- Subscriber 3: Compliance (Specific Symbols) ---
    const ComplianceSystem = struct {
        fn audit(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            std.log.info("📋 Compliance: Auditing regulated symbol {d}", .{event.model_id});
            // Log for regulatory reporting
            // Check trading restrictions
        }
    };

    const compliance_filter = message_bus.Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .in, .value = "AAPL,MSFT,GOOGL" },
        },
    };
    _ = try bus.subscribe("Trade.created", compliance_filter, ComplianceSystem.audit);

    // --- Simulate Trades ---
    std.log.info("\n--- Simulating Trades ---\n", .{});

    // Trade 1: Small TSLA (triggers: portfolio only)
    bus.publish(Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{\"symbol\":\"TSLA\",\"price\":5000,\"quantity\":10}",
    });

    // Trade 2: Large AAPL (triggers: portfolio, risk, compliance)
    bus.publish(Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 2,
        .data = "{\"symbol\":\"AAPL\",\"price\":15000,\"quantity\":100}",
    });

    // Trade 3: Trade update (triggers: portfolio only)
    bus.publish(Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_updated,
        .topic = "Trade.updated",
        .model_type = "Trade",
        .model_id = 2,
        .data = "{\"symbol\":\"AAPL\",\"price\":15500,\"quantity\":100}",
    });

    std.Thread.sleep(300 * std.time.ns_per_ms);

    const stats = bus.getStats();
    std.log.info("\n✓ Processed {d} events", .{stats.published});
}

// ============================================================================
// MAIN: Run All Examples
// ============================================================================

pub fn main() !void {
    try example1_basicSetup();
    try example2_simplePublishSubscribe();
    try example3_filteredSubscriptions();
    try example4_multipleFilters();
    try example5_wildcardTopics();
    try example6_multipleSubscribers();
    try example7_statistics();
    try example8_allOperators();
    try example9_realWorldTradeSystem();

    std.log.info("\n\n🎉 All examples completed successfully!\n", .{});
}
