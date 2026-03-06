/// Ping handler - simple health check
/// Tiger Style: NEVER THROWS - all errors are values

const std = @import("std");
const Allocator = std.mem.Allocator;
const result = @import("result");

pub const MESSAGE_TYPE: u8 = 2;

/// Simple context
pub const Context = struct {
    server_start_time: i64,

    pub fn init() Context {
        return .{
            .server_start_time = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *Context) void {
        _ = self;
        // Cleanup if needed
    }
};

/// Ping request/response are simple
const PingRequest = struct {
    timestamp: i64,
};

const PongResponse = struct {
    request_timestamp: i64,
    server_timestamp: i64,
    uptime_ms: i64,
};

/// Tiger Style: Returns HandlerResponse, NEVER THROWS!
pub fn handle(
    context: *Context,
    request_data: []const u8,
    response_buffer: []u8,
    allocator: Allocator,
) result.HandlerResponse {
    _ = allocator;

    // Validate buffer size - error as value, not exception
    if (response_buffer.len < 24) {
        return result.HandlerResponse.err(.handler_failed);
    }

    // Parse request timestamp (8 bytes, big-endian)
    const request_timestamp = if (request_data.len >= 8)
        std.mem.readInt(i64, request_data[0..8], .big)
    else
        0;

    const now = std.time.milliTimestamp();

    const response = PongResponse{
        .request_timestamp = request_timestamp,
        .server_timestamp = now,
        .uptime_ms = now - context.server_start_time,
    };

    // Encode response (simple binary format) - NO ERRORS POSSIBLE!
    std.mem.writeInt(i64, response_buffer[0..8], response.request_timestamp, .big);
    std.mem.writeInt(i64, response_buffer[8..16], response.server_timestamp, .big);
    std.mem.writeInt(i64, response_buffer[16..24], response.uptime_ms, .big);

    // Success - return value, not error union
    return result.HandlerResponse.ok(response_buffer[0..24]);
}

// Note: No register() function needed!
// The HandlerRegistry automatically discovers and registers this handler
