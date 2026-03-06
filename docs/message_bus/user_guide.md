# Message Bus - User Guide

**For Handler Developers**

This guide shows you how to use the message bus in your handlers to build event-driven, reactive applications.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Core Concepts](#core-concepts)
3. [Publishing Events](#publishing-events)
4. [Subscribing to Events](#subscribing-to-events)
5. [Available Topics](#available-topics)
6. [Filters and Conditions](#filters-and-conditions)
7. [Complete Handler Example](#complete-handler-example)
8. [Testing Your Handler](#testing-your-handler)
9. [Best Practices](#best-practices)
10. [Common Patterns](#common-patterns)

---

## Quick Start

### 1. Import the Message Bus

```zig
const message_bus = @import("../src/message_bus/mod.zig");
```

### 2. Subscribe to Events in Your Handler

```zig
pub const Context = struct {
    message_bus: ?*message_bus.MessageBus,
    subscription_id: ?message_bus.SubscriptionId,

    pub fn postInit(self: *Context, allocator: Allocator) !void {
        const globals = @import("../src/globals.zig");
        self.message_bus = globals.global_message_bus;

        if (self.message_bus) |bus| {
            const filter = message_bus.Filter{ .conditions = &.{} };
            self.subscription_id = try bus.subscribe(
                message_bus.ModelTopics("Item").created,  // ← Type-safe topic
                filter,
                onItemCreated,
            );
        }
    }
};

fn onItemCreated(event: *const Event, allocator: Allocator) void {
    std.log.info("Item created: {s}", .{event.data});
}
```

### 3. Publish Events

```zig
// Simple one-liner
message_bus.publishEvent(message_bus.CustomTopic("Item.processed"), json_data);
```

That's it! No need to know about Event internals, IDs, timestamps, or any other complexity.

---

## Core Concepts

### What is the Message Bus?

The message bus is a **Kafka-like pub/sub system** that enables:

- **Reactive handlers** - Handlers react to events from other parts of the system
- **Decoupled architecture** - Handlers don't need to know about each other
- **Event-driven workflows** - One handler's output triggers another handler's input
- **Parallel execution** - Multiple handlers process the same event concurrently

### How It Works

```
Handler A                    Message Bus                    Handler B
   │                              │                              │
   │──publish("Item.created")────>│                              │
   │                              │──────notifies────────────────>│
   │                              │                              │
   │                              │                         onItemCreated()
   │                              │                              │
   │                              │<───publish("Order.created")──│
   │                              │                              │
   │<──────notifies───────────────│                              │
   │                              │                              │
onOrderCreated()                  │                              │
```

### Key Features

- **Compile-time topic validation** - Typos caught at compile time, not runtime
- **Lock-free publishing** - < 1µs latency to publish an event
- **Background delivery** - Events delivered asynchronously by worker threads
- **Filtered subscriptions** - Only receive events matching your criteria
- **Persistent audit log** - All events saved to ClickHouse

---

## Publishing Events

### Simple Publishing (Most Common)

```zig
// Just topic + data
message_bus.publishEvent(message_bus.CustomTopic("Item.processed"), json_data);
```

**When to use:** Most of the time. Just publish an event with data.

### Publishing with Model Context

```zig
// Include model type and ID
message_bus.publishModelEvent(
    message_bus.CustomTopic("Order.completed"),
    "Order",          // model_type
    order.id,         // model_id
    json_data,
);
```

**When to use:** When subscribers need to know which specific model instance triggered the event.

### Advanced Publishing (Full Control)

```zig
// Fluent builder API
message_bus.EventBuilder.init(message_bus.ModelTopics("User").created)
    .modelType("User")
    .modelId(42)
    .data(user_json)
    .eventType(.model_created)
    .publish(bus);
```

**When to use:** Rarely needed. Use when you need fine-grained control over event fields.

### Example: Publishing from a Handler

```zig
pub fn handle(
    context: *Context,
    request_data: []const u8,
    response_buffer: []u8,
    allocator: Allocator,
) result.HandlerResponse {
    // Parse request
    const item = parseItem(request_data) catch {
        return result.HandlerResponse.err(.malformed_message);
    };

    // Process item
    processItem(item);

    // Publish event (one line!)
    var buffer: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buffer,
        "{{\"name\":\"{s}\",\"price\":{d}}}",
        .{item.name, item.price}
    ) catch return result.HandlerResponse.err(.handler_failed);

    message_bus.publishEvent(message_bus.CustomTopic("Item.processed"), json);

    return result.HandlerResponse.ok(response);
}
```

---

## Subscribing to Events

### Basic Subscription

```zig
pub fn subscribe(self: *Context) !void {
    if (self.message_bus) |bus| {
        const filter = message_bus.Filter{ .conditions = &.{} };  // Match all

        self.subscription_id = try bus.subscribe(
            message_bus.ModelTopics("Item").created,  // Topic to listen to
            filter,                           // Filter (empty = match all)
            onItemCreated,                    // Callback function
        );
    }
}

fn onItemCreated(event: *const Event, allocator: Allocator) void {
    // Your event handler logic
    std.log.info("Item created: {s}", .{event.data});
}
```

### Subscription with Filters

```zig
pub fn subscribe(self: *Context) !void {
    if (self.message_bus) |bus| {
        // Only high-value items
        const high_value_filter = message_bus.Filter{
            .conditions = &.{
                .{ .field = "price", .op = .gt, .value = "100000" },
            },
        };

        self.high_value_sub = try bus.subscribe(
            message_bus.ModelTopics("Item").created,
            high_value_filter,
            onHighValueItem,
        );
    }
}
```

### Multiple Subscriptions

```zig
pub fn subscribe(self: *Context) !void {
    if (self.message_bus) |bus| {
        const filter = message_bus.Filter{ .conditions = &.{} };

        // Subscribe to multiple topics
        self.item_created_sub = try bus.subscribe(
            message_bus.ModelTopics("Item").created,
            filter,
            onItemCreated,
        );

        self.item_updated_sub = try bus.subscribe(
            message_bus.ModelTopics("Item").updated,
            filter,
            onItemUpdated,
        );

        self.item_deleted_sub = try bus.subscribe(
            message_bus.ModelTopics("Item").deleted,
            filter,
            onItemDeleted,
        );
    }
}
```

### Wildcard Subscriptions

```zig
// Subscribe to ALL item events (created, updated, deleted, etc.)
self.all_items_sub = try bus.subscribe(
    message_bus.ModelTopics("Item").wildcard,  // "Item.*" - matches all Item topics
    filter,
    onAnyItemEvent,
);
```

### Unsubscribing (Cleanup)

```zig
pub fn deinit(self: *Context) void {
    if (self.message_bus) |bus| {
        if (self.subscription_id) |id| {
            bus.unsubscribe(id);
        }
    }
}
```

---

## Available Topics

Topics are declared by the entities that own them using comptime generators. No central registry file needed.

### ModelTopics -- Standard CRUD Topics

Use `ModelTopics` for any entity with standard create/update/delete lifecycle:

```zig
const UserTopics = message_bus.ModelTopics("User");
// UserTopics.created   -> "User.created"
// UserTopics.updated   -> "User.updated"
// UserTopics.deleted   -> "User.deleted"
// UserTopics.wildcard  -> "User.*"
```

Works with any entity name -- `"Item"`, `"Order"`, `"Notification"`, `"Alert"`, etc.

### FeedTopics -- Exchange Feed Topics

```zig
const ItchTopics = message_bus.FeedTopics("itch");
// ItchTopics.received  -> "Feed.itch"
// ItchTopics.wildcard  -> "Feed.*"
```

### CustomTopic -- Non-Standard Events

For events that don't fit the created/updated/deleted pattern:

```zig
const processed = message_bus.CustomTopic("Item.processed");
const completed = message_bus.CustomTopic("Order.completed");
const cancelled = message_bus.CustomTopic("Order.cancelled");
```

### SystemTopics -- Infrastructure Events

```zig
message_bus.SystemTopics.startup       // "System.startup"
message_bus.SystemTopics.shutdown      // "System.shutdown"
message_bus.SystemTopics.health_check  // "System.health_check"
message_bus.SystemTopics.wildcard      // "System.*"
```

### Adding New Topics

No file to edit. Just use the appropriate generator:

```zig
// Standard CRUD entity -- use ModelTopics
message_bus.publishEvent(message_bus.ModelTopics("Payment").created, data);

// Custom event -- use CustomTopic
message_bus.publishEvent(message_bus.CustomTopic("Payment.refunded"), data);
```

Topic format is validated at compile time. Topics must match `"Category.event"` format (exactly one dot, non-empty on both sides).

---

## Filters and Conditions

Filters let you subscribe only to events matching specific criteria.

### Filter Structure

```zig
pub const Filter = struct {
    conditions: []const WhereClause,
};

pub const WhereClause = struct {
    field: []const u8,      // JSON field path
    op: Op,                 // Comparison operator
    value: []const u8,      // Expected value (as string)
};

pub const Op = enum {
    eq,      // Equal
    ne,      // Not equal
    gt,      // Greater than
    gte,     // Greater than or equal
    lt,      // Less than
    lte,     // Less than or equal
    like,    // String pattern match
    in,      // In list
    not_in,  // Not in list
};
```

### Filter Examples

**High-value items (price > 100000):**

```zig
const filter = message_bus.Filter{
    .conditions = &.{
        .{ .field = "price", .op = .gt, .value = "100000" },
    },
};
```

**Active users only:**

```zig
const filter = message_bus.Filter{
    .conditions = &.{
        .{ .field = "status", .op = .eq, .value = "active" },
    },
};
```

**Multiple conditions (AND logic):**

```zig
const filter = message_bus.Filter{
    .conditions = &.{
        .{ .field = "price", .op = .gt, .value = "1000" },
        .{ .field = "status", .op = .eq, .value = "pending" },
        .{ .field = "category", .op = .ne, .value = "archived" },
    },
};
```

**Date range:**

```zig
const filter = message_bus.Filter{
    .conditions = &.{
        .{ .field = "created_at", .op = .gte, .value = "2026-03-01" },
        .{ .field = "created_at", .op = .lt, .value = "2026-04-01" },
    },
};
```

---

## Complete Handler Example

Here's a complete handler demonstrating all message bus features:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const result = @import("result");
const message_bus = @import("../src/message_bus/mod.zig");
const Event = @import("../src/event.zig").Event;

pub const MESSAGE_TYPE: u8 = 30;

pub const Context = struct {
    message_bus: ?*message_bus.MessageBus,
    allocator: Allocator,

    // Subscription IDs
    item_created_sub: ?message_bus.SubscriptionId,
    high_value_sub: ?message_bus.SubscriptionId,

    // Statistics
    items_processed: std.atomic.Value(u64),
    high_value_count: std.atomic.Value(u64),

    pub fn init() Context {
        return .{
            .message_bus = null,
            .allocator = undefined,
            .item_created_sub = null,
            .high_value_sub = null,
            .items_processed = std.atomic.Value(u64).init(0),
            .high_value_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn postInit(self: *Context, allocator: Allocator) !void {
        self.allocator = allocator;

        // Get global message bus
        const globals = @import("../src/globals.zig");
        self.message_bus = globals.global_message_bus;

        // Subscribe to events
        if (self.message_bus) |_| {
            try self.subscribe();
            std.log.info("Handler subscribed to message bus", .{});
        }
    }

    pub fn subscribe(self: *Context) !void {
        if (self.message_bus) |bus| {
            // Subscribe to all item creations
            const all_filter = message_bus.Filter{ .conditions = &.{} };
            self.item_created_sub = try bus.subscribe(
                message_bus.ModelTopics("Item").created,
                all_filter,
                onItemCreated,
            );

            // Subscribe to high-value items only
            const high_value_filter = message_bus.Filter{
                .conditions = &.{
                    .{ .field = "price", .op = .gt, .value = "100000" },
                },
            };
            self.high_value_sub = try bus.subscribe(
                message_bus.ModelTopics("Item").created,
                high_value_filter,
                onHighValueItem,
            );
        }
    }

    pub fn deinit(self: *Context) void {
        if (self.message_bus) |bus| {
            if (self.item_created_sub) |id| bus.unsubscribe(id);
            if (self.high_value_sub) |id| bus.unsubscribe(id);
        }
    }
};

// Event handler: All items
fn onItemCreated(event: *const Event, allocator: Allocator) void {
    std.log.info("Item created - ID: {d}, Data: {s}", .{
        event.model_id,
        event.data,
    });

    // Parse and process event data
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        event.data,
        .{},
    ) catch return;
    defer parsed.deinit();

    // Extract fields
    const root = parsed.value.object;
    const name = root.get("name").?.string;
    const price = root.get("price").?.integer;

    std.log.info("  Name: {s}, Price: ${d}", .{name, price});
}

// Event handler: High-value items only
fn onHighValueItem(event: *const Event, allocator: Allocator) void {
    _ = allocator;
    std.log.warn("HIGH VALUE ITEM ALERT - ID: {d}", .{event.model_id});

    // Send notifications, trigger workflows, etc.
}

// Main handler function
pub fn handle(
    context: *Context,
    request_data: []const u8,
    response_buffer: []u8,
    allocator: Allocator,
) result.HandlerResponse {
    _ = context.items_processed.fetchAdd(1, .monotonic);

    // Parse request
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        request_data,
        .{},
    ) catch return result.HandlerResponse.err(.malformed_message);
    defer parsed.deinit();

    const obj = parsed.value.object;
    const name = obj.get("name").?.string;
    const price = obj.get("price").?.integer;

    // Validate
    if (price <= 0) {
        return result.HandlerResponse.err(.invalid_field);
    }

    // Publish event (one line!)
    var buffer: [1024]u8 = undefined;
    const data = std.fmt.bufPrint(&buffer,
        "{{\"name\":\"{s}\",\"price\":{d}}}",
        .{name, price}
    ) catch return result.HandlerResponse.err(.handler_failed);

    message_bus.publishEvent(message_bus.CustomTopic("Item.processed"), data);

    // Build response
    const response = std.fmt.bufPrint(response_buffer,
        "{{\"status\":\"success\",\"name\":\"{s}\"}}",
        .{name}
    ) catch return result.HandlerResponse.err(.message_too_large);

    return result.HandlerResponse.ok(response);
}
```

---

## Testing Your Handler

### Unit Test Example

```zig
test "handler processes and publishes event" {
    const allocator = std.testing.allocator;

    var context = Context.init();
    defer context.deinit();
    context.allocator = allocator;

    const request = "{\"name\":\"widget\",\"price\":15000}";
    var response_buffer: [4096]u8 = undefined;

    const response = handle(&context, request, &response_buffer, allocator);

    try std.testing.expect(response == .ok);
    try std.testing.expectEqual(@as(u64, 1),
        context.items_processed.load(.acquire));
}
```

### Integration Test (with Message Bus)

```zig
test "handler reacts to events" {
    const allocator = std.testing.allocator;

    // Initialize message bus
    var bus = try message_bus.MessageBus.init(allocator, .{});
    defer bus.deinit();
    try bus.start();

    // Create handler context
    var context = Context.init();
    defer context.deinit();

    context.message_bus = &bus;
    try context.subscribe();

    // Publish test event
    message_bus.publishEvent(
        message_bus.ModelTopics("Item").created,
        "{\"name\":\"test\",\"price\":5000}"
    );

    // Wait for delivery
    std.time.sleep(100 * std.time.ns_per_ms);

    // Verify handler was called (check logs or counters)
}
```

---

## Best Practices

### 1. Always Clean Up Subscriptions

```zig
pub fn deinit(self: *Context) void {
    if (self.message_bus) |bus| {
        if (self.subscription_id) |id| {
            bus.unsubscribe(id);  // ← Always unsubscribe!
        }
    }
}
```

### 2. Use ModelTopics / CustomTopic (Never Raw Strings)

```zig
// ✅ GOOD - Compile-time validated
message_bus.publishEvent(message_bus.ModelTopics("Item").created, data);
message_bus.publishEvent(message_bus.CustomTopic("Item.processed"), data);

// ❌ BAD - Typo becomes runtime bug
message_bus.publishEvent("Item.crated", data);  // Oops!
```

### 3. Keep Event Handlers Fast

Event handlers run on background worker threads. Keep them fast (< 100µs):

```zig
// ✅ GOOD - Fast logging
fn onItemCreated(event: *const Event, allocator: Allocator) void {
    _ = allocator;
    std.log.info("Item {d} created", .{event.model_id});
}

// ❌ BAD - Slow database query
fn onItemCreated(event: *const Event, allocator: Allocator) void {
    const result = database.query("SELECT * FROM ..."); // DON'T block here!
}
```

If you need to do slow work, publish another event or use a queue.

### 4. Handle JSON Parsing Errors

```zig
fn onItemCreated(event: *const Event, allocator: Allocator) void {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        event.data,
        .{},
    ) catch {
        std.log.err("Failed to parse event data", .{});
        return;  // ← Graceful failure
    };
    defer parsed.deinit();

    // Process...
}
```

### 5. Use Filters to Reduce Load

Don't subscribe to everything if you only need specific events:

```zig
// ✅ GOOD - Only high-value items
const filter = message_bus.Filter{
    .conditions = &.{
        .{ .field = "price", .op = .gt, .value = "100000" },
    },
};

// ❌ BAD - Subscribe to all, filter manually
const filter = message_bus.Filter{ .conditions = &.{} };
// Then check price in handler (wastes CPU)
```

### 6. Never Throw from Event Handlers

Event handlers use Tiger Style - never throw exceptions:

```zig
// ✅ GOOD - Tiger Style
fn onItemCreated(event: *const Event, allocator: Allocator) void {
    const result = processItem(event) catch {
        std.log.err("Failed to process item", .{});
        return;  // ← Handle error, return normally
    };
}

// ❌ BAD - Don't throw!
fn onItemCreated(event: *const Event, allocator: Allocator) !void {
    try processItem(event);  // ← DON'T do this!
}
```

---

## Common Patterns

### Pattern 1: Handler Chain Reaction

Handler A processes a request, publishes an event. Handler B reacts to that event.

```zig
// Handler A: Process order
pub fn handle(...) result.HandlerResponse {
    // Process order
    const order = processOrder(request_data);

    // Publish event
    message_bus.publishEvent(
        message_bus.ModelTopics("Order").created,
        order_json
    );

    return result.HandlerResponse.ok(response);
}

// Handler B: Auto-subscribe in postInit
pub fn postInit(self: *Context, allocator: Allocator) !void {
    // ... get message bus ...

    self.subscription = try bus.subscribe(
        message_bus.ModelTopics("Order").created,  // ← Listen to Handler A
        filter,
        onOrderCreated,
    );
}

fn onOrderCreated(event: *const Event, allocator: Allocator) void {
    // React to Handler A's event
    sendNotification(event.data);
}
```

### Pattern 2: Aggregation

Collect events and publish summary:

```zig
pub const Context = struct {
    order_count: std.atomic.Value(u64),

    // In event handler
    fn onOrderCreated(event: *const Event, allocator: Allocator) void {
        _ = allocator;
        const count = context.order_count.fetchAdd(1, .monotonic);

        if (count % 100 == 0) {
            // Every 100 orders, publish summary
            message_bus.publishEvent(
                message_bus.ModelTopics("Notification").created,
                summary_data
            );
        }
    }
};
```

### Pattern 3: Conditional Workflows

Route events based on data:

```zig
fn onItemCreated(event: *const Event, allocator: Allocator) void {
    const parsed = std.json.parseFromSlice(...) catch return;
    defer parsed.deinit();

    const price = parsed.value.object.get("price").?.integer;

    if (price > 100000) {
        // High-value workflow
        message_bus.publishEvent(
            message_bus.ModelTopics("Alert").created,
            alert_data
        );
    } else {
        // Normal workflow
        message_bus.publishEvent(
            message_bus.ModelTopics("Notification").created,
            notification_data
        );
    }
}
```

### Pattern 4: Fan-Out

One event triggers multiple independent actions:

```zig
// When order is created, trigger:
// - Inventory update
// - Email notification
// - Analytics tracking
// - Shipping workflow

// All subscribe to the same topic:
bus.subscribe(message_bus.ModelTopics("Order").created, filter, updateInventory);
bus.subscribe(message_bus.ModelTopics("Order").created, filter, sendEmail);
bus.subscribe(message_bus.ModelTopics("Order").created, filter, trackAnalytics);
bus.subscribe(message_bus.ModelTopics("Order").created, filter, createShipment);

// All handlers execute in parallel!
```

---

## Summary

### Key Takeaways

1. **Use `ModelTopics` / `CustomTopic`** - Never use raw strings
2. **Subscribe in `postInit()`** - Use the lifecycle hook
3. **Publish with `publishEvent()`** - Simple one-liner
4. **Keep handlers fast** - < 100µs per event handler
5. **Clean up** - Always unsubscribe in `deinit()`
6. **Tiger Style** - Never throw from event handlers

### Quick Reference

```zig
// Import
const message_bus = @import("../src/message_bus/mod.zig");

// Subscribe
self.sub_id = try bus.subscribe(
    message_bus.ModelTopics("Item").created,
    message_bus.Filter{ .conditions = &.{} },
    onItemCreated,
);

// Publish
message_bus.publishEvent(message_bus.CustomTopic("Item.processed"), data);

// Unsubscribe
bus.unsubscribe(self.sub_id);
```

### Need Help?

- See `handlers/example_handler.zig` for a complete working example
- See [Contributor Guide](contributor_guide.md) if working on the bus itself

---

**Last Updated:** 2026-03-06
**Framework Version:** 0.3.0-alpha
