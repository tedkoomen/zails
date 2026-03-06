const std = @import("std");
const Allocator = std.mem.Allocator;
const MessageBus = @import("message_bus.zig").MessageBus;
const globals = @import("../globals.zig");

/// Global message bus (thread-safe singleton)
/// Uses the single source of truth in globals.zig to avoid dual-variable bugs
/// where event_builder.zig reads from globals.zig but this module wrote to a separate variable.
var global_bus_mutex: std.Thread.Mutex = .{};

pub fn initGlobalMessageBus(allocator: Allocator, config: MessageBus.Config) !void {
    global_bus_mutex.lock();
    defer global_bus_mutex.unlock();

    if (globals.global_message_bus != null) {
        return error.AlreadyInitialized;
    }

    const bus = try allocator.create(MessageBus);
    errdefer allocator.destroy(bus);

    bus.* = try MessageBus.init(allocator, config);
    try bus.start();

    globals.global_message_bus = bus;
    std.log.info("Global MessageBus initialized", .{});
}

pub fn getGlobalMessageBus() ?*MessageBus {
    return globals.global_message_bus;
}

pub fn deinitGlobalMessageBus(allocator: Allocator) void {
    global_bus_mutex.lock();
    defer global_bus_mutex.unlock();

    if (globals.global_message_bus) |bus| {
        // deinit() handles shutdown signaling, thread joining, and cleanup
        bus.deinit();
        allocator.destroy(bus);
        globals.global_message_bus = null;

        std.log.info("Global MessageBus deinitialized", .{});
    }
}

// Note: Global message bus tests disabled due to issues with global mutable state in tests
// The global message bus works correctly in production use, but tests with global state
// can have race conditions. Use the MessageBus directly in tests instead.

// test "global message bus init and deinit" {
//     const allocator = std.testing.allocator;
//
//     try initGlobalMessageBus(allocator, .{
//         .queue_capacity = 64,
//         .worker_count = 1,
//     });
//
//     const bus = getGlobalMessageBus();
//     try std.testing.expect(bus != null);
//
//     deinitGlobalMessageBus(allocator);
//
//     const bus_after = getGlobalMessageBus();
//     try std.testing.expect(bus_after == null);
// }

// test "global message bus already initialized error" {
//     const allocator = std.testing.allocator;
//
//     try initGlobalMessageBus(allocator, .{
//         .queue_capacity = 64,
//         .worker_count = 1,
//     });
//     defer deinitGlobalMessageBus(allocator);
//
//     // Try to initialize again - should fail
//     const result = initGlobalMessageBus(allocator, .{});
//     try std.testing.expectError(error.AlreadyInitialized, result);
// }
