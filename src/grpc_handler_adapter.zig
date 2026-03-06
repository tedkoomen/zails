/// gRPC Handler Adapter - Adapts existing handlers to gRPC interface
/// Maintains Tiger Style: errors as values, never throws
/// Keeps sub-100µs latency by avoiding allocations and using stack buffers

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("proto.zig");
const result = @import("result.zig");

/// Adapt a standard handler to gRPC-style request/response
pub fn GrpcHandlerAdapter(comptime Handler: type) type {
    return struct {
        const Self = @This();

        /// Context is the same as the underlying handler
        pub const Context = Handler.Context;

        /// Handle gRPC request (decode, delegate, encode)
        /// Returns HandlerResponse (Tiger Style - never throws)
        pub fn handleGrpc(
            context: *Context,
            grpc_req: *const proto.GrpcRequest,
            response_buffer: []u8,
            allocator: Allocator,
        ) result.HandlerResponse {
            // Delegate to underlying handler with payload
            const handler_response = Handler.handle(
                context,
                grpc_req.payload,
                response_buffer,
                allocator,
            );

            // Handler response is already a HandlerResponse (no conversion needed)
            return handler_response;
        }

        /// Wrap handler response in gRPC response envelope
        pub fn wrapGrpcResponse(
            request_id: []const u8,
            handler_response: result.HandlerResponse,
            output_buffer: []u8,
        ) result.HandlerResponse {
            // Build gRPC response
            const grpc_response = proto.GrpcResponse{
                .request_id = request_id,
                .status_code = if (handler_response.isOk()) .ok else serverErrorToGrpcStatus(handler_response.error_code),
                .status_message = if (handler_response.isErr()) handler_response.error_code.toString() else "",
                .payload = handler_response.data,
            };

            // Encode gRPC response
            const encoded_len = proto.encodeGrpcResponse(&grpc_response, output_buffer) catch {
                return result.HandlerResponse.err(.handler_failed);
            };

            return result.HandlerResponse.ok(output_buffer[0..encoded_len]);
        }

        /// Convert ServerError to GrpcStatus
        fn serverErrorToGrpcStatus(err: result.ServerError) proto.GrpcStatus {
            return switch (err) {
                .none => .ok,
                .connection_closed => .unavailable,
                .connection_timeout => .deadline_exceeded,
                .connection_limit_reached => .resource_exhausted,
                .invalid_header => .invalid_argument,
                .message_too_large => .invalid_argument,
                .malformed_message => .invalid_argument,
                .unknown_message_type => .unimplemented,
                .pool_exhausted => .resource_exhausted,
                .queue_full => .resource_exhausted,
                .out_of_memory => .resource_exhausted,
                .handler_not_found => .not_found,
                .handler_failed => .internal,
                .handler_timeout => .deadline_exceeded,
                .read_failed => .unavailable,
                .write_failed => .unavailable,
            };
        }
    };
}

// Tests
test "grpc handler adapter basic" {
    const allocator = std.testing.allocator;

    // Mock handler
    const MockHandler = struct {
        pub const MESSAGE_TYPE: u8 = 42;

        pub const Context = struct {
            call_count: u32,

            pub fn init() @This() {
                return .{ .call_count = 0 };
            }

            pub fn deinit(self: *@This()) void {
                _ = self;
            }
        };

        pub fn handle(
            ctx: *Context,
            request_data: []const u8,
            response_buffer: []u8,
            alloc: Allocator,
        ) result.HandlerResponse {
            _ = alloc;
            ctx.call_count += 1;

            // Echo the request
            const len = @min(request_data.len, response_buffer.len);
            @memcpy(response_buffer[0..len], request_data[0..len]);
            return result.HandlerResponse.ok(response_buffer[0..len]);
        }
    };

    const Adapter = GrpcHandlerAdapter(MockHandler);

    // Create context
    var ctx = MockHandler.Context.init();
    defer ctx.deinit();

    // Create gRPC request
    var grpc_req = proto.GrpcRequest.init(allocator);
    defer grpc_req.deinit(allocator);

    grpc_req.base.request_id = try allocator.dupe(u8, "test-123");
    grpc_req.service = try allocator.dupe(u8, "TestService");
    grpc_req.method = try allocator.dupe(u8, "TestMethod");
    grpc_req.payload = try allocator.dupe(u8, "hello");

    // Handle request
    var response_buffer: [1024]u8 = undefined;
    const handler_resp = Adapter.handleGrpc(&ctx, &grpc_req, &response_buffer, allocator);

    // Verify
    try std.testing.expect(handler_resp.isOk());
    try std.testing.expectEqualStrings("hello", handler_resp.data);
    try std.testing.expectEqual(@as(u32, 1), ctx.call_count);

    // Wrap in gRPC response
    var output_buffer: [2048]u8 = undefined;
    const grpc_resp = Adapter.wrapGrpcResponse("test-123", handler_resp, &output_buffer);

    try std.testing.expect(grpc_resp.isOk());
}

test "grpc handler adapter error handling" {
    const allocator = std.testing.allocator;

    // Mock failing handler
    const FailingHandler = struct {
        pub const MESSAGE_TYPE: u8 = 99;

        pub const Context = struct {
            pub fn init() @This() {
                return .{};
            }

            pub fn deinit(self: *@This()) void {
                _ = self;
            }
        };

        pub fn handle(
            ctx: *Context,
            request_data: []const u8,
            response_buffer: []u8,
            alloc: Allocator,
        ) result.HandlerResponse {
            _ = ctx;
            _ = request_data;
            _ = response_buffer;
            _ = alloc;

            return result.HandlerResponse.err(.handler_failed);
        }
    };

    const Adapter = GrpcHandlerAdapter(FailingHandler);

    var ctx = FailingHandler.Context.init();
    defer ctx.deinit();

    var grpc_req = proto.GrpcRequest.init(allocator);
    defer grpc_req.deinit(allocator);

    grpc_req.base.request_id = try allocator.dupe(u8, "fail-456");
    grpc_req.service = try allocator.dupe(u8, "FailService");
    grpc_req.method = try allocator.dupe(u8, "FailMethod");
    grpc_req.payload = try allocator.dupe(u8, "data");

    var response_buffer: [1024]u8 = undefined;
    const handler_resp = Adapter.handleGrpc(&ctx, &grpc_req, &response_buffer, allocator);

    // Verify error propagation
    try std.testing.expect(handler_resp.isErr());
    try std.testing.expectEqual(result.ServerError.handler_failed, handler_resp.error_code);

    // Wrap error in gRPC response
    var output_buffer: [2048]u8 = undefined;
    const grpc_resp = Adapter.wrapGrpcResponse("fail-456", handler_resp, &output_buffer);

    try std.testing.expect(grpc_resp.isOk()); // Wrapper succeeds even for errors
}
