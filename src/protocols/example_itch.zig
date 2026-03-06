/// Example ITCH Protocol Definition
///
/// Demonstrates how to define binary protocols for UDP feed parsing.
/// This defines a subset of NASDAQ ITCH 5.0 message types.
///
/// To add a new protocol:
///   1. Create a new file in protocols/ (e.g., protocols/my_protocol.zig)
///   2. Define message types using BinaryProtocol()
///   3. Export PROTOCOL_ID (unique u8) and TOPIC
///   4. Add to the FeedProtocols tuple in main.zig

const udp = @import("../udp/mod.zig");

/// Protocol identifier — must be unique across all protocols
/// Maps to FeedConfig.protocol_id at runtime
pub const PROTOCOL_ID: u8 = 1;

/// Default message bus topic for this feed
pub const TOPIC = "Feed.itch";

/// ITCH Add Order message (message type 'A')
/// Represents a new order added to the book
pub const AddOrder = udp.BinaryProtocol("ITCH_AddOrder", .{
    .msg_type = .{ .type = .u8, .offset = 0 },
    .stock_locate = .{ .type = .u16, .offset = 1 },
    .tracking_num = .{ .type = .u16, .offset = 3 },
    .timestamp_ns = .{ .type = .u64, .offset = 5 },
    .order_ref = .{ .type = .u64, .offset = 13 },
    .side = .{ .type = .u8, .offset = 21 },
    .shares = .{ .type = .u32, .offset = 22 },
    .stock = .{ .type = .ascii, .offset = 26, .size = 8 },
    .price = .{ .type = .u32, .offset = 34 },
});

/// ITCH Trade message (message type 'P')
/// Represents an execution (non-cross)
pub const Trade = udp.BinaryProtocol("ITCH_Trade", .{
    .msg_type = .{ .type = .u8, .offset = 0 },
    .stock_locate = .{ .type = .u16, .offset = 1 },
    .tracking_num = .{ .type = .u16, .offset = 3 },
    .timestamp_ns = .{ .type = .u64, .offset = 5 },
    .order_ref = .{ .type = .u64, .offset = 13 },
    .side = .{ .type = .u8, .offset = 21 },
    .shares = .{ .type = .u32, .offset = 22 },
    .stock = .{ .type = .ascii, .offset = 26, .size = 8 },
    .price = .{ .type = .u32, .offset = 34 },
    .match_number = .{ .type = .u64, .offset = 38 },
});

/// ITCH Order Cancel message (message type 'X')
/// Represents a partial cancellation
pub const OrderCancel = udp.BinaryProtocol("ITCH_OrderCancel", .{
    .msg_type = .{ .type = .u8, .offset = 0 },
    .stock_locate = .{ .type = .u16, .offset = 1 },
    .tracking_num = .{ .type = .u16, .offset = 3 },
    .timestamp_ns = .{ .type = .u64, .offset = 5 },
    .order_ref = .{ .type = .u64, .offset = 13 },
    .cancelled_shares = .{ .type = .u32, .offset = 21 },
});

// ====================
// Tests
// ====================

const std = @import("std");

test "ITCH AddOrder parse" {
    var data: [38]u8 = undefined;
    data[0] = 'A';
    std.mem.writeInt(u16, data[1..3], 42, .big);
    std.mem.writeInt(u16, data[3..5], 0, .big);
    std.mem.writeInt(u64, data[5..13], 1234567890, .big);
    std.mem.writeInt(u64, data[13..21], 100001, .big);
    data[21] = 'B';
    std.mem.writeInt(u32, data[22..26], 500, .big);
    @memcpy(data[26..34], "AAPL    ");
    std.mem.writeInt(u32, data[34..38], 15000, .big);

    const result = AddOrder.parse(&data);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqual(@as(u8, 'A'), result.msg.msg_type);
    try std.testing.expectEqual(@as(u32, 500), result.msg.shares);
    try std.testing.expectEqualStrings("AAPL    ", &result.msg.stock);
}

test "ITCH Trade parse" {
    try std.testing.expectEqual(@as(usize, 46), Trade.MIN_MESSAGE_SIZE);
}

test "ITCH OrderCancel parse" {
    try std.testing.expectEqual(@as(usize, 25), OrderCancel.MIN_MESSAGE_SIZE);
}
