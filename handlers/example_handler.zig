/// Example Handler - Simple Template
/// Tiger Style: NEVER THROWS - all errors are values
///
/// This handler demonstrates basic request/response processing.
/// For message bus integration examples, see docs/message_bus/usage_example.zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const result = @import("result");

/// Message type ID for example handler
pub const MESSAGE_TYPE: u8 = 20;

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

/// Handler context
pub const Context = struct {
    allocator: Allocator,

    // Statistics
    requests_processed: std.atomic.Value(u64),

    pub fn init() Context {
        return .{
            .allocator = undefined, // Will be set in postInit
            .requests_processed = std.atomic.Value(u64).init(0),
        };
    }

    /// Post-initialization hook - called after server startup
    pub fn postInit(self: *Context, allocator: Allocator) !void {
        self.allocator = allocator;
        std.log.info("✓ Example handler initialized", .{});
    }

    pub fn deinit(self: *Context) void {
        _ = self;
    }
};

/// Process request (Tiger Style - NEVER THROWS)
pub fn handle(
    context: *Context,
    request_data: []const u8,
    response_buffer: []u8,
    allocator: Allocator,
) result.HandlerResponse {
    _ = context.requests_processed.fetchAdd(1, .monotonic);

    // Validate request
    if (request_data.len == 0) {
        return result.HandlerResponse.err(.malformed_message);
    }

    // Parse request (JSON format)
    // Format: {"name":"value","count":123}
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        request_data,
        .{},
    ) catch {
        return result.HandlerResponse.err(.malformed_message);
    };
    defer parsed.deinit();

    // Validate parsed JSON is an object
    if (parsed.value != .object) {
        return result.HandlerResponse.err(.malformed_message);
    }
    const obj = parsed.value.object;

    const name_val = obj.get("name") orelse {
        return result.HandlerResponse.err(.malformed_message);
    };
    const count_val_json = obj.get("count") orelse {
        return result.HandlerResponse.err(.malformed_message);
    };

    // Validate types before accessing
    if (name_val != .string or count_val_json != .integer) {
        return result.HandlerResponse.err(.malformed_message);
    }

    const count_val = count_val_json.integer;

    // Validate
    if (count_val <= 0) {
        return result.HandlerResponse.err(.malformed_message);
    }

    var stream = std.io.fixedBufferStream(response_buffer);
    const writer = stream.writer();
    writer.writeAll("{\"status\":\"success\",\"name\":") catch {
        return result.HandlerResponse.err(.message_too_large);
    };
    writeJsonString(writer, name_val.string) catch {
        return result.HandlerResponse.err(.message_too_large);
    };
    writer.print(",\"count\":{d}}}", .{count_val}) catch {
        return result.HandlerResponse.err(.message_too_large);
    };

    return result.HandlerResponse.ok(stream.getWritten());
}

// ============================================================================
// Tests
// ============================================================================

test "example handler processes valid request" {
    const allocator = std.testing.allocator;

    var context = Context.init();
    defer context.deinit();
    context.allocator = allocator;

    const request = "{\"name\":\"test\",\"count\":42}";
    var response_buffer: [4096]u8 = undefined;

    const response = handle(&context, request, &response_buffer, allocator);

    try std.testing.expect(response.isOk());
    try std.testing.expectEqual(@as(u64, 1), context.requests_processed.load(.acquire));
}

test "example handler rejects invalid request" {
    const allocator = std.testing.allocator;

    var context = Context.init();
    defer context.deinit();
    context.allocator = allocator;

    const request = "{\"name\":\"test\",\"count\":-1}";
    var response_buffer: [4096]u8 = undefined;

    const response = handle(&context, request, &response_buffer, allocator);

    try std.testing.expect(response.isErr());
}

test "example handler escapes JSON response strings" {
    const allocator = std.testing.allocator;

    var context = Context.init();
    defer context.deinit();
    context.allocator = allocator;

    const request = "{\"name\":\"a\\\"b\\n\",\"count\":1}";
    var response_buffer: [4096]u8 = undefined;

    const response = handle(&context, request, &response_buffer, allocator);

    try std.testing.expect(response.isOk());
    try std.testing.expect(std.mem.indexOf(u8, response.data, "\"name\":\"a\\\"b\\n\"") != null);
}
