/// Metrics handler - exposes Prometheus metrics endpoint
/// Message type 255 reserved for metrics
/// Tiger Style: NEVER THROWS - all errors are values

const std = @import("std");
const Allocator = std.mem.Allocator;
const globals = if (@hasDecl(@import("root"), "globals")) @import("root").globals else struct {};
const result = @import("result");

pub const MESSAGE_TYPE: u8 = 255;

pub const Context = struct {
    pub fn init() Context {
        return .{};
    }

    pub fn deinit(self: *Context) void {
        _ = self;
    }
};

/// Handle metrics request - Tiger Style (NEVER THROWS!)
/// Returns HandlerResponse with error_code instead of error union
/// Returns Prometheus exposition format by default
/// Send "json" in request for JSON format
pub fn handle(
    context: *Context,
    request_data: []const u8,
    response_buffer: []u8,
    allocator: Allocator,
) result.HandlerResponse {
    _ = context;

    if (comptime !@hasDecl(globals, "global_metrics")) {
        const err_msg = "Metrics not available";
        const len = @min(err_msg.len, response_buffer.len);
        @memcpy(response_buffer[0..len], err_msg[0..len]);
        return result.HandlerResponse.ok(response_buffer[0..len]);
    }

    // Get global metrics registry
    const metrics = globals.global_metrics orelse {
        const err_msg = "Metrics not enabled";
        const len = @min(err_msg.len, response_buffer.len);
        @memcpy(response_buffer[0..len], err_msg[0..len]);
        return result.HandlerResponse.ok(response_buffer[0..len]);
    };

    // Check format
    const format = if (request_data.len > 0 and std.mem.eql(u8, request_data, "json"))
        Format.json
    else
        Format.prometheus;

    const output = switch (format) {
        .prometheus => metrics.exportPrometheus(allocator) catch {
            return result.HandlerResponse.err(.handler_failed);
        },
        .json => metrics.exportJSON(allocator) catch {
            return result.HandlerResponse.err(.handler_failed);
        },
    };
    defer allocator.free(output);

    // Copy to response buffer — return error if truncated
    if (output.len > response_buffer.len) {
        std.log.warn("Metrics output truncated: {d} bytes available, {d} bytes needed", .{ response_buffer.len, output.len });
    }
    const len = @min(output.len, response_buffer.len);
    @memcpy(response_buffer[0..len], output[0..len]);

    return result.HandlerResponse.ok(response_buffer[0..len]);
}

const Format = enum {
    prometheus,
    json,
};
