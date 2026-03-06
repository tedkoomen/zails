/// Control handler - runtime configuration changes
/// Message type 254 reserved for control commands
/// Non-blocking control plane for profiling/metrics toggles
/// Tiger Style: NEVER THROWS - all errors are values

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const globals = if (@hasDecl(@import("root"), "globals")) @import("root").globals else struct {};
const result = @import("result");

pub const MESSAGE_TYPE: u8 = 254;

pub const Context = struct {
    pub fn init() Context {
        return .{};
    }

    pub fn deinit(self: *Context) void {
        _ = self;
    }
};

/// Handle control commands - Tiger Style (NEVER THROWS!)
/// Returns HandlerResponse with error_code instead of error union
/// Commands:
///   metrics:enable / metrics:disable
///   profiling:enable / profiling:disable
///   cpu_profiling:enable / cpu_profiling:disable
///   memory_profiling:enable / memory_profiling:disable
///   status - Get current status
pub fn handle(
    context: *Context,
    request_data: []const u8,
    response_buffer: []u8,
    allocator: Allocator,
) result.HandlerResponse {
    _ = context;
    _ = allocator;

    if (comptime !@hasDecl(globals, "global_runtime_controller")) {
        return result.HandlerResponse.err(.handler_failed);
    }

    // Get runtime controller (global)
    const runtime_controller = globals.global_runtime_controller orelse {
        return result.HandlerResponse.err(.handler_failed);
    };

    const command = std.mem.trim(u8, request_data, &std.ascii.whitespace);

    if (std.mem.eql(u8, command, "metrics:enable")) {
        runtime_controller.enableMetrics();
        const msg = "Metrics enabled";
        const len = @min(msg.len, response_buffer.len);
        @memcpy(response_buffer[0..len], msg[0..len]);
        return result.HandlerResponse.ok(response_buffer[0..len]);
    } else if (std.mem.eql(u8, command, "metrics:disable")) {
        runtime_controller.disableMetrics();
        const msg = "Metrics disabled";
        const len = @min(msg.len, response_buffer.len);
        @memcpy(response_buffer[0..len], msg[0..len]);
        return result.HandlerResponse.ok(response_buffer[0..len]);
    } else if (std.mem.eql(u8, command, "profiling:enable")) {
        runtime_controller.enableProfiling();
        const msg = "Profiling enabled";
        const len = @min(msg.len, response_buffer.len);
        @memcpy(response_buffer[0..len], msg[0..len]);
        return result.HandlerResponse.ok(response_buffer[0..len]);
    } else if (std.mem.eql(u8, command, "profiling:disable")) {
        runtime_controller.disableProfiling();
        const msg = "Profiling disabled";
        const len = @min(msg.len, response_buffer.len);
        @memcpy(response_buffer[0..len], msg[0..len]);
        return result.HandlerResponse.ok(response_buffer[0..len]);
    } else if (std.mem.eql(u8, command, "status")) {
        const metrics_status = if (runtime_controller.isMetricsEnabled()) "enabled" else "disabled";
        const profiling_status = if (runtime_controller.isProfilingEnabled()) "enabled" else "disabled";

        const msg = std.fmt.bufPrint(
            response_buffer,
            "Metrics: {s}\nProfiling: {s}",
            .{ metrics_status, profiling_status },
        ) catch {
            return result.HandlerResponse.err(.message_too_large);
        };
        return result.HandlerResponse.ok(msg);
    } else {
        return result.HandlerResponse.err(.malformed_message);
    }
}
