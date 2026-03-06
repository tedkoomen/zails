/// Feed Manager - Multi-feed lifecycle management
///
/// Manages multiple UDP feed listener threads.
/// Parameterized by comptime protocol tuple (same pattern as HandlerRegistry).
///
/// Usage:
///   const FM = FeedManager(FeedProtocols);
///   var fm = try FM.init(allocator, feeds, &bus);
///   try fm.start();
///   defer fm.deinit();

const std = @import("std");
const Allocator = std.mem.Allocator;
const MessageBus = @import("../message_bus/message_bus.zig").MessageBus;
const FeedConfig = @import("feed_config.zig").FeedConfig;
const udp_listener = @import("udp_listener.zig");
const SequenceTracker = @import("sequence_tracker.zig").SequenceTracker;

pub fn FeedManager(comptime Protocols: anytype) type {
    const Listener = udp_listener.UdpListener(Protocols);

    return struct {
        const Self = @This();

        listeners: []Listener,
        threads: []std.Thread,
        shutdown: std.atomic.Value(bool),
        started: bool,
        active_count: usize,
        allocator: Allocator,

        pub fn init(
            allocator: Allocator,
            feeds: []const FeedConfig,
            bus: *MessageBus,
        ) !Self {
            // Count enabled feeds
            var enabled_count: usize = 0;
            for (feeds) |f| {
                if (f.enabled) enabled_count += 1;
            }

            var self = Self{
                .listeners = try allocator.alloc(Listener, enabled_count),
                .threads = try allocator.alloc(std.Thread, enabled_count),
                .shutdown = std.atomic.Value(bool).init(false),
                .started = false,
                .active_count = enabled_count,
                .allocator = allocator,
            };

            // Initialize listeners for enabled feeds
            var idx: usize = 0;
            errdefer {
                for (self.listeners[0..idx]) |*listener| {
                    listener.deinit();
                }
                allocator.free(self.listeners);
                allocator.free(self.threads);
            }

            for (feeds) |feed| {
                if (!feed.enabled) continue;

                self.listeners[idx] = try Listener.init(
                    feed,
                    bus,
                    &self.shutdown,
                    allocator,
                );
                idx += 1;
            }

            std.log.info("FeedManager initialized with {} feed(s)", .{enabled_count});
            return self;
        }

        /// Start all feed listener threads
        pub fn start(self: *Self) !void {
            var spawned: usize = 0;
            errdefer {
                // On failure, signal shutdown and join already-spawned threads
                self.shutdown.store(true, .release);
                for (self.threads[0..spawned]) |thread| {
                    thread.join();
                }
            }

            for (self.listeners, 0..) |*listener, i| {
                self.threads[i] = try std.Thread.spawn(.{}, Listener.run, .{listener});
                spawned += 1;
            }

            self.started = true;
            std.log.info("FeedManager started {} listener thread(s)", .{spawned});
        }

        /// Shutdown all listeners and join threads
        pub fn deinit(self: *Self) void {
            self.shutdown.store(true, .release);

            if (self.started) {
                for (self.threads[0..self.active_count]) |thread| {
                    thread.join();
                }
            }

            for (self.listeners) |*listener| {
                listener.deinit();
            }

            self.allocator.free(self.listeners);
            self.allocator.free(self.threads);
        }

        /// Aggregate stats from all listeners
        pub fn getStats(self: *Self) AggregateStats {
            var total = AggregateStats{};
            for (self.listeners) |*listener| {
                const s = listener.getStats();
                total.datagrams_received += s.datagrams_received;
                total.parse_errors += s.parse_errors;
                total.bytes_received += s.bytes_received;
                total.events_published += s.events_published;
            }
            total.active_feeds = self.active_count;
            return total;
        }

        pub const AggregateStats = struct {
            datagrams_received: u64 = 0,
            parse_errors: u64 = 0,
            bytes_received: u64 = 0,
            events_published: u64 = 0,
            active_feeds: usize = 0,
        };
    };
}

// ====================
// Tests
// ====================

test "FeedManager compiles with protocol tuple" {
    const binary_protocol = @import("binary_protocol.zig");
    const TestProto = binary_protocol.BinaryProtocol("Test", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
    });

    const TestProtocols = .{
        .{ .PROTOCOL_ID = @as(u8, 1), .Parser = TestProto, .TOPIC = "Feed.test" },
    };

    const FM = FeedManager(TestProtocols);

    // Verify the type compiles and has expected declarations
    try std.testing.expect(@hasDecl(FM, "init"));
    try std.testing.expect(@hasDecl(FM, "start"));
    try std.testing.expect(@hasDecl(FM, "deinit"));
    try std.testing.expect(@hasDecl(FM, "getStats"));
}

test "FeedManager multiple protocols compile" {
    const binary_protocol = @import("binary_protocol.zig");
    const Proto1 = binary_protocol.BinaryProtocol("Proto1", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
    });
    const Proto2 = binary_protocol.BinaryProtocol("Proto2", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
        .value = .{ .type = .u32, .offset = 1 },
    });

    const MultiProtocols = .{
        .{ .PROTOCOL_ID = @as(u8, 1), .Parser = Proto1, .TOPIC = "Feed.p1" },
        .{ .PROTOCOL_ID = @as(u8, 2), .Parser = Proto2, .TOPIC = "Feed.p2" },
    };

    const FM = FeedManager(MultiProtocols);
    try std.testing.expect(@hasDecl(FM, "init"));
    try std.testing.expect(@hasDecl(FM, "AggregateStats"));
}

test "FeedManager AggregateStats defaults" {
    const binary_protocol = @import("binary_protocol.zig");
    const TestProto = binary_protocol.BinaryProtocol("Test", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
    });

    const TestProtocols = .{
        .{ .PROTOCOL_ID = @as(u8, 1), .Parser = TestProto, .TOPIC = "Feed.test" },
    };

    const FM = FeedManager(TestProtocols);
    const stats = FM.AggregateStats{};

    try std.testing.expectEqual(@as(u64, 0), stats.datagrams_received);
    try std.testing.expectEqual(@as(u64, 0), stats.parse_errors);
    try std.testing.expectEqual(@as(u64, 0), stats.bytes_received);
    try std.testing.expectEqual(@as(u64, 0), stats.events_published);
    try std.testing.expectEqual(@as(usize, 0), stats.active_feeds);
}
