/// Feed Configuration Types
///
/// Runtime configuration for UDP feed listeners.
/// Protocol layouts are comptime-only; this config specifies which ports,
/// multicast groups, and protocol IDs to use at runtime.
///
/// String ownership: All []const u8 fields are borrowed. UdpListener.init()
/// dupes the strings it needs, so callers do not need to keep FeedConfig
/// alive after passing it to the listener.

const std = @import("std");

/// Configuration for a single UDP feed listener
pub const FeedConfig = struct {
    name: []const u8, // "nasdaq_itch_a"
    bind_address: []const u8, // "0.0.0.0"
    bind_port: u16, // 5000
    multicast_group: ?[]const u8, // "239.1.2.3" or null
    multicast_interface: ?[]const u8, // Interface IP or null (INADDR_ANY)
    protocol_id: u8, // Maps to comptime protocol (like MESSAGE_TYPE)
    enabled: bool,
    recv_buffer_size: usize, // SO_RCVBUF (16MB+ recommended)
    publish_topic: []const u8, // Message bus topic, e.g. "Feed.itch"
    initial_sequence: u64, // Starting sequence number for gap detection (0 = auto)
};

/// Top-level feeds configuration
pub const FeedsConfig = struct {
    enabled: bool,
    feeds: []const FeedConfig,
};

/// Default feed config values for convenience
pub fn defaultFeedConfig(name: []const u8, port: u16, protocol_id: u8, topic: []const u8) FeedConfig {
    return .{
        .name = name,
        .bind_address = "0.0.0.0",
        .bind_port = port,
        .multicast_group = null,
        .multicast_interface = null,
        .protocol_id = protocol_id,
        .enabled = true,
        .recv_buffer_size = 16 * 1024 * 1024, // 16MB
        .publish_topic = topic,
        .initial_sequence = 0,
    };
}

// ====================
// Tests
// ====================

test "defaultFeedConfig produces expected values" {
    const config = defaultFeedConfig("test_feed", 5000, 1, "Feed.test");

    try std.testing.expectEqualStrings("test_feed", config.name);
    try std.testing.expectEqualStrings("0.0.0.0", config.bind_address);
    try std.testing.expectEqual(@as(u16, 5000), config.bind_port);
    try std.testing.expectEqual(@as(?[]const u8, null), config.multicast_group);
    try std.testing.expectEqual(@as(?[]const u8, null), config.multicast_interface);
    try std.testing.expectEqual(@as(u8, 1), config.protocol_id);
    try std.testing.expect(config.enabled);
    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024), config.recv_buffer_size);
    try std.testing.expectEqualStrings("Feed.test", config.publish_topic);
    try std.testing.expectEqual(@as(u64, 0), config.initial_sequence);
}

test "FeedConfig struct layout" {
    // Verify all fields exist and can be set
    const config = FeedConfig{
        .name = "nasdaq_itch_a",
        .bind_address = "10.0.1.5",
        .bind_port = 26400,
        .multicast_group = "239.1.2.3",
        .multicast_interface = "10.0.1.1",
        .protocol_id = 42,
        .enabled = false,
        .recv_buffer_size = 32 * 1024 * 1024,
        .publish_topic = "Feed.itch.add_order",
        .initial_sequence = 1000,
    };

    try std.testing.expectEqualStrings("nasdaq_itch_a", config.name);
    try std.testing.expectEqual(@as(u16, 26400), config.bind_port);
    try std.testing.expectEqualStrings("239.1.2.3", config.multicast_group.?);
    try std.testing.expectEqualStrings("10.0.1.1", config.multicast_interface.?);
    try std.testing.expectEqual(@as(u8, 42), config.protocol_id);
    try std.testing.expect(!config.enabled);
    try std.testing.expectEqual(@as(u64, 1000), config.initial_sequence);
}
