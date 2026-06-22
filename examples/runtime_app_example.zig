const std = @import("std");
const zails = @import("zails");

fn nativeEcho(
    request_ptr: [*]const u8,
    request_len: usize,
    response_ptr: [*]u8,
    response_cap: usize,
) callconv(.c) zails.CHandlerResult {
    if (request_len > response_cap) return zails.nativeErr(.message_too_large);

    const request = request_ptr[0..request_len];
    const response = response_ptr[0..request_len];
    @memcpy(response, request);
    return zails.nativeOk(request_len);
}

const EchoHandler = zails.NativeForeignHandler(50, nativeEcho);

const App = zails.App(.{
    .handlers = .{EchoHandler},
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var registry = try App.init(gpa.allocator());
    defer registry.deinit();

    var response_buffer: [1024]u8 = undefined;
    const response = registry.handle(50, "hello runtime", &response_buffer, gpa.allocator());
    if (response.isErr()) return error.HandlerFailed;

    std.debug.print("{s}\n", .{response.data});
}
