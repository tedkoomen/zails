/// analytics_handler handler
/// Tiger Style: NEVER THROWS - all errors are values

const std = @import("std");
const Allocator = std.mem.Allocator;
const result = @import("result");

pub const MESSAGE_TYPE: u8 = 4;

pub const Context = struct {
    request_count: std.atomic.Value(u64),

    pub fn init() Context {
        return .{
            .request_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Context) void {
        _ = self;
    }
};

/// Handler function - Tiger Style (NEVER THROWS!)
/// Returns HandlerResponse with error_code instead of error union
pub fn handle(
    context: *Context,
    request_data: []const u8,
    response_buffer: []u8,
    allocator: Allocator,
) result.HandlerResponse {
    _ = context.request_count.fetchAdd(1, .monotonic);
    _ = allocator;

    // Validate input
    if (request_data.len == 0) {
        return result.HandlerResponse.err(.malformed_message);
    }

    if (request_data.len > response_buffer.len) {
        return result.HandlerResponse.err(.message_too_large);
    }

    // Echo back the request data
    const len = @min(request_data.len, response_buffer.len);
    @memcpy(response_buffer[0..len], request_data[0..len]);

    return result.HandlerResponse.ok(response_buffer[0..len]);
}
