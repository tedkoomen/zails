const std = @import("std");
const zails = @import("zails");
const options = @import("cpp_runtime_options");

const Trade = zails.ReactiveModel("Trade", .{
    .symbol = .String,
    .price = .i64,
    .quantity = .u64,
    .active = .bool,
});

const CppModelHandler = zails.TcpForeignHandler(.{
    .message_type = 210,
    .host = "127.0.0.1",
    .port = options.worker_port,
});

fn callCppWorkerWithRetries(
    context: *CppModelHandler.Context,
    payload: []const u8,
    response_buffer: []u8,
    allocator: std.mem.Allocator,
) zails.HandlerResponse {
    var response = zails.HandlerResponse.err(.connection_timeout);
    for (0..50) |_| {
        response = CppModelHandler.handle(context, payload, response_buffer, allocator);
        if (response.isOk() or response.error_code != .connection_timeout) return response;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return response;
}

test "C++ worker consumes model JSON from imported Zails runtime" {
    const allocator = std.testing.allocator;
    const port_arg = std.fmt.comptimePrint("{d}", .{options.worker_port});

    var child = std.process.Child.init(&.{ options.worker_path, port_arg }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    var child_done = false;
    defer if (!child_done) {
        _ = child.kill() catch {};
    };

    var trade = Trade.init(allocator, null);
    defer trade.deinit();

    try trade.set("symbol", "AAPL");
    try trade.set("price", @as(i64, 15000));
    try trade.set("quantity", @as(u64, 25));
    try trade.set("active", true);

    var json_buffer: [512]u8 = undefined;
    const payload = try trade.toJSON(&json_buffer);

    var context = CppModelHandler.Context.init();
    defer context.deinit();

    var response_buffer: [256]u8 = undefined;
    const response = callCppWorkerWithRetries(&context, payload, &response_buffer, allocator);

    const term = try child.wait();
    child_done = true;

    try std.testing.expect(response.isOk());
    try std.testing.expectEqualStrings(
        "cpp saw Trade model: symbol=AAPL price=15000 quantity=25 active=true",
        response.data,
    );
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
}
