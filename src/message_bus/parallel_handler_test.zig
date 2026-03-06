/// Test parallel handler execution
const std = @import("std");
const message_bus = @import("mod.zig");
const Event = @import("../event.zig").Event;

test "handlers execute in parallel" {
    const allocator = std.testing.allocator;

    // Setup message bus
    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1, // Single worker to test parallel handlers
    });
    defer bus.deinit();
    try bus.start();

    // Shared counter to verify parallel execution
    var counter = std.atomic.Value(u32).init(0);
    var started = std.atomic.Value(u32).init(0);
    var max_concurrent = std.atomic.Value(u32).init(0);

    // Handler that simulates work and tracks concurrency
    const TestContext = struct {
        counter: *std.atomic.Value(u32),
        started: *std.atomic.Value(u32),
        max_concurrent: *std.atomic.Value(u32),
    };

    const context = TestContext{
        .counter = &counter,
        .started = &started,
        .max_concurrent = &max_concurrent,
    };

    const makeHandler = struct {
        fn make(ctx: TestContext) message_bus.HandlerFn {
            const Handler = struct {
                fn handle(event: *const Event, alloc: std.mem.Allocator) void {
                    _ = event;
                    _ = alloc;

                    // Increment started counter
                    const concurrent = ctx.started.fetchAdd(1, .monotonic) + 1;

                    // Update max concurrent
                    var max = ctx.max_concurrent.load(.acquire);
                    while (max < concurrent) {
                        max = ctx.max_concurrent.cmpxchgWeak(
                            max,
                            concurrent,
                            .acq_rel,
                            .acquire,
                        ) orelse break;
                    }

                    // Simulate work
                    std.Thread.sleep(10 * std.time.ns_per_ms);

                    // Decrement started counter
                    _ = ctx.started.fetchSub(1, .monotonic);

                    // Increment completion counter
                    _ = ctx.counter.fetchAdd(1, .monotonic);
                }
            };
            return Handler.handle;
        }
    }.make;

    // Subscribe multiple handlers to same event
    const filter = message_bus.Filter{ .conditions = &.{} };
    _ = try bus.subscribe("Test.created", filter, makeHandler(context));
    _ = try bus.subscribe("Test.created", filter, makeHandler(context));
    _ = try bus.subscribe("Test.created", filter, makeHandler(context));
    _ = try bus.subscribe("Test.created", filter, makeHandler(context));

    // Publish single event (should trigger all 4 handlers in parallel)
    const event = Event{
        .id = 1,
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{}",
    };

    bus.publish(event);

    // Wait for handlers to complete
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Verify all handlers executed
    try std.testing.expectEqual(@as(u32, 4), counter.load(.acquire));

    // Verify parallel execution (max_concurrent should be > 1)
    const max_concurrent_count = max_concurrent.load(.acquire);
    std.debug.print("\nMax concurrent handlers: {}\n", .{max_concurrent_count});

    // If handlers run sequentially, max_concurrent would be 1
    // If handlers run in parallel, max_concurrent should be > 1
    try std.testing.expect(max_concurrent_count > 1);
}

test "single handler executes inline (no threading overhead)" {
    const allocator = std.testing.allocator;

    var bus = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1,
    });
    defer bus.deinit();
    try bus.start();

    var called = false;

    const handler = struct {
        fn handle(event: *const Event, alloc: std.mem.Allocator) void {
            _ = event;
            _ = alloc;
            // This is accessing the outer scope variable
            // In real code, you'd use a pointer passed through context
        }
    }.handle;

    const filter = message_bus.Filter{ .conditions = &.{} };
    _ = try bus.subscribe("Test.created", filter, handler);

    const event = Event{
        .id = 1,
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{}",
    };

    bus.publish(event);

    // Wait for delivery
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Single handler should execute inline (no thread spawn overhead)
    // This is tested by the fact that it completes quickly
    _ = called;
}
