/// UDP Feed Module - Public Exports
///
/// Provides high-performance UDP feed support for exchange connectivity.
/// Comptime protocol definitions generate zero-cost parsers.
///
/// Example:
///   const udp = @import("udp/mod.zig");
///
///   // Define a protocol
///   const AddOrder = udp.BinaryProtocol("ITCH_AddOrder", .{
///       .msg_type = .{ .type = .u8, .offset = 0 },
///       .shares   = .{ .type = .u32, .offset = 1 },
///   });
///
///   // Create protocol registry (comptime tuple)
///   const FeedProtocols = .{
///       .{ .PROTOCOL_ID = 1, .Parser = AddOrder, .TOPIC = "Feed.itch" },
///   };
///
///   // Create and start feed manager
///   const FM = udp.FeedManager(FeedProtocols);
///   var fm = try FM.init(allocator, feeds, &bus);
///   try fm.start();
///   defer fm.deinit();

// Core protocol generator
pub const BinaryProtocol = @import("binary_protocol.zig").BinaryProtocol;
pub const BinaryFieldDef = @import("binary_protocol.zig").BinaryFieldDef;
pub const BinaryFieldType = @import("binary_protocol.zig").BinaryFieldType;
pub const FeedError = @import("binary_protocol.zig").FeedError;

// UDP listener
pub const UdpListener = @import("udp_listener.zig").UdpListener;

// Feed manager
pub const FeedManager = @import("feed_manager.zig").FeedManager;

// Configuration types
pub const FeedConfig = @import("feed_config.zig").FeedConfig;
pub const FeedsConfig = @import("feed_config.zig").FeedsConfig;
pub const defaultFeedConfig = @import("feed_config.zig").defaultFeedConfig;

// Sequence tracking
pub const SequenceTracker = @import("sequence_tracker.zig").SequenceTracker;

test {
    // Run all tests in sub-modules
    @import("std").testing.refAllDecls(@This());
}
