/// Generic test client for Zerver
/// Supports sending different message types to test handlers

const std = @import("std");
const net = std.net;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.log.info("Usage: {s} <port> [message_type] [data]", .{args[0]});
        std.log.info("  message_type: 1=echo (default), 2=ping", .{});
        std.log.info("  data: message to send (for echo)", .{});
        return;
    }

    const port = try std.fmt.parseInt(u16, args[1], 10);
    const msg_type: u8 = if (args.len > 2)
        try std.fmt.parseInt(u8, args[2], 10)
    else
        1;

    const data = if (args.len > 3) args[3] else "Hello, Zerver!";

    std.log.info("Connecting to localhost:{}...", .{port});

    const address = try net.Address.parseIp("127.0.0.1", port);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    std.log.info("Connected! Sending message type {}", .{msg_type});

    // Prepare request based on message type
    var request_data: [4096]u8 = undefined;
    var request_len: usize = 0;

    switch (msg_type) {
        1 => { // Echo
            request_len = @min(data.len, request_data.len);
            @memcpy(request_data[0..request_len], data[0..request_len]);
        },
        2 => { // Ping
            const timestamp = std.time.milliTimestamp();
            std.mem.writeInt(i64, request_data[0..8], timestamp, .big);
            request_len = 8;
        },
        else => {
            std.log.err("Unknown message type: {}", .{msg_type});
            return error.UnknownMessageType;
        },
    }

    // Send request: [1 byte: type][4 bytes: length][N bytes: data]
    var header: [5]u8 = undefined;
    header[0] = msg_type;
    std.mem.writeInt(u32, header[1..5], @as(u32, @intCast(request_len)), .big);

    try stream.writeAll(&header);
    try stream.writeAll(request_data[0..request_len]);

    // Read response: [1 byte: type][4 bytes: length][N bytes: data]
    var response_header: [5]u8 = undefined;
    const header_read = try stream.read(&response_header);
    if (header_read < 5) return error.InvalidResponse;

    const response_type = response_header[0];
    const response_len = std.mem.readInt(u32, response_header[1..5], .big);

    if (response_len > request_data.len) return error.ResponseTooLarge;

    var response_data: [4096]u8 = undefined;
    const data_read = try stream.read(response_data[0..response_len]);
    if (data_read < response_len) return error.IncompleteResponse;

    std.log.info("Received response (type {}): {} bytes", .{ response_type, response_len });

    // Parse response based on type
    switch (msg_type) {
        1 => { // Echo
            std.log.info("  Echo: {s}", .{response_data[0..response_len]});
        },
        2 => { // Ping/Pong
            if (response_len >= 24) {
                const req_ts = std.mem.readInt(i64, response_data[0..8], .big);
                const srv_ts = std.mem.readInt(i64, response_data[8..16], .big);
                const uptime = std.mem.readInt(i64, response_data[16..24], .big);
                std.log.info("  Request timestamp: {}", .{req_ts});
                std.log.info("  Server timestamp: {}", .{srv_ts});
                std.log.info("  Server uptime: {}ms", .{uptime});
                std.log.info("  RTT: {}ms", .{srv_ts - req_ts});
            }
        },
        else => {},
    }
}
