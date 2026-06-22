/// Comprehensive integration tests for gRPC components
/// Tests proto.zig, grpc_registry.zig, and grpc_handler_adapter.zig together

const std = @import("std");
const proto = @import("proto.zig");
const grpc_registry = @import("grpc_registry.zig");
const grpc_handler_adapter = @import("grpc_handler_adapter.zig");
const result = @import("result.zig");

test "grpc end-to-end: request encoding -> routing -> handler -> response" {
    const allocator = std.testing.allocator;

    // Define service registry
    const services = [_]proto.ServiceMethod{
        .{ .service_name = "UserService", .method_name = "GetUser", .message_type = 10 },
        .{ .service_name = "UserService", .method_name = "CreateUser", .message_type = 11 },
        .{ .service_name = "PostService", .method_name = "ListPosts", .message_type = 20 },
    };

    const Registry = grpc_registry.GrpcServiceRegistry(&services);

    // Create a mock handler
    const MockHandler = struct {
        pub const MESSAGE_TYPE: u8 = 10;

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
            alloc: std.mem.Allocator,
        ) result.HandlerResponse {
            _ = ctx;
            _ = alloc;
            // Echo back the payload
            const len = @min(request_data.len, response_buffer.len);
            @memcpy(response_buffer[0..len], request_data[0..len]);
            return result.HandlerResponse.ok(response_buffer[0..len]);
        }
    };

    const Adapter = grpc_handler_adapter.GrpcHandlerAdapter(MockHandler);

    // Step 1: Create gRPC request
    var grpc_req = proto.GrpcRequest.init(allocator);
    defer grpc_req.deinit(allocator);

    grpc_req.base.request_id = try allocator.dupe(u8, "test-123");
    grpc_req.service = try allocator.dupe(u8, "UserService");
    grpc_req.method = try allocator.dupe(u8, "GetUser");
    grpc_req.payload = try allocator.dupe(u8, "user_id=42");

    // Step 2: Encode gRPC request
    var encoded_buffer: [4096]u8 = undefined;
    const encoded_len = try proto.encodeGrpcRequest(&grpc_req, &encoded_buffer);

    // Step 3: Decode gRPC request (simulating network)
    var decoded_req = try proto.decodeGrpcRequest(allocator, encoded_buffer[0..encoded_len]);
    defer decoded_req.deinit(allocator);

    // Step 4: Route to handler
    const msg_type = Registry.route(decoded_req.service, decoded_req.method);
    try std.testing.expectEqual(@as(?u8, 10), msg_type);

    // Step 5: Call handler via adapter
    var ctx = MockHandler.Context.init();
    defer ctx.deinit();

    var response_buffer: [4096]u8 = undefined;
    const handler_resp = Adapter.handleGrpc(&ctx, &decoded_req, &response_buffer, allocator);

    try std.testing.expect(handler_resp.isOk());
    try std.testing.expectEqualStrings("user_id=42", handler_resp.data);

    // Step 6: Wrap in gRPC response
    var grpc_response_buffer: [4096]u8 = undefined;
    const grpc_resp = Adapter.wrapGrpcResponse(decoded_req.base.request_id, handler_resp, &grpc_response_buffer);

    try std.testing.expect(grpc_resp.isOk());

    // Step 7: Decode and verify gRPC response
    var final_response = try proto.decodeGrpcResponse(allocator, grpc_resp.data);
    defer final_response.deinit(allocator);

    try std.testing.expectEqualStrings("test-123", final_response.request_id);
    try std.testing.expectEqual(proto.GrpcStatus.ok, final_response.status_code);
    try std.testing.expectEqualStrings("user_id=42", final_response.payload);
}

test "grpc error handling: unknown service" {
    const services = [_]proto.ServiceMethod{
        .{ .service_name = "UserService", .method_name = "GetUser", .message_type = 10 },
    };

    const Registry = grpc_registry.GrpcServiceRegistry(&services);

    const msg_type = Registry.route("UnknownService", "UnknownMethod");
    try std.testing.expectEqual(@as(?u8, null), msg_type);
}

test "grpc error handling: handler failure propagation" {
    const allocator = std.testing.allocator;

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
            alloc: std.mem.Allocator,
        ) result.HandlerResponse {
            _ = ctx;
            _ = request_data;
            _ = response_buffer;
            _ = alloc;
            return result.HandlerResponse.err(.handler_failed);
        }
    };

    const Adapter = grpc_handler_adapter.GrpcHandlerAdapter(FailingHandler);

    var grpc_req = proto.GrpcRequest.init(allocator);
    defer grpc_req.deinit(allocator);

    grpc_req.base.request_id = try allocator.dupe(u8, "fail-999");
    grpc_req.payload = try allocator.dupe(u8, "data");

    var ctx = FailingHandler.Context.init();
    defer ctx.deinit();

    var response_buffer: [4096]u8 = undefined;
    const handler_resp = Adapter.handleGrpc(&ctx, &grpc_req, &response_buffer, allocator);

    try std.testing.expect(handler_resp.isErr());
    try std.testing.expectEqual(result.ServerError.handler_failed, handler_resp.error_code);

    // Verify error is wrapped in gRPC response with correct status
    var grpc_response_buffer: [4096]u8 = undefined;
    const grpc_resp = Adapter.wrapGrpcResponse("fail-999", handler_resp, &grpc_response_buffer);

    try std.testing.expect(grpc_resp.isOk()); // Wrapper succeeds

    var final_response = try proto.decodeGrpcResponse(allocator, grpc_resp.data);
    defer final_response.deinit(allocator);

    try std.testing.expectEqual(proto.GrpcStatus.internal, final_response.status_code);
}

test "grpc metadata propagation" {
    const allocator = std.testing.allocator;

    var grpc_req = proto.GrpcRequest.init(allocator);
    defer grpc_req.deinit(allocator);

    grpc_req.base.request_id = try allocator.dupe(u8, "meta-123");
    grpc_req.base.timestamp = 1234567890;

    // Add metadata
    try grpc_req.base.metadata.put(
        try allocator.dupe(u8, "user-agent"),
        try allocator.dupe(u8, "ZailsClient/1.0"),
    );
    try grpc_req.base.metadata.put(
        try allocator.dupe(u8, "auth-token"),
        try allocator.dupe(u8, "secret-token-xyz"),
    );

    grpc_req.service = try allocator.dupe(u8, "TestService");
    grpc_req.method = try allocator.dupe(u8, "TestMethod");
    grpc_req.payload = try allocator.dupe(u8, "payload");

    // Encode and decode
    var buffer: [4096]u8 = undefined;
    const encoded_len = try proto.encodeGrpcRequest(&grpc_req, &buffer);

    var decoded = try proto.decodeGrpcRequest(allocator, buffer[0..encoded_len]);
    defer decoded.deinit(allocator);

    // Verify metadata preserved
    try std.testing.expectEqual(@as(usize, 2), decoded.base.metadata.count());

    const user_agent = decoded.base.metadata.get("user-agent");
    try std.testing.expectEqualStrings("ZailsClient/1.0", user_agent.?);

    const auth_token = decoded.base.metadata.get("auth-token");
    try std.testing.expectEqualStrings("secret-token-xyz", auth_token.?);
}

test "grpc large payload handling" {
    const allocator = std.testing.allocator;

    // Create a large payload (10KB)
    const large_payload = try allocator.alloc(u8, 10 * 1024);
    defer allocator.free(large_payload);

    for (large_payload, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    var grpc_req = proto.GrpcRequest.init(allocator);
    defer grpc_req.deinit(allocator);

    grpc_req.base.request_id = try allocator.dupe(u8, "large-123");
    grpc_req.service = try allocator.dupe(u8, "BlobService");
    grpc_req.method = try allocator.dupe(u8, "Upload");
    grpc_req.payload = try allocator.dupe(u8, large_payload);

    // Encode
    const buffer = try allocator.alloc(u8, 20 * 1024);
    defer allocator.free(buffer);

    const encoded_len = try proto.encodeGrpcRequest(&grpc_req, buffer);

    // Decode
    var decoded = try proto.decodeGrpcRequest(allocator, buffer[0..encoded_len]);
    defer decoded.deinit(allocator);

    // Verify large payload is preserved
    try std.testing.expectEqual(large_payload.len, decoded.payload.len);
    try std.testing.expectEqualSlices(u8, large_payload, decoded.payload);
}
