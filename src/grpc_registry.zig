/// gRPC Service Registry - Comptime routing from service.method -> MESSAGE_TYPE
/// Maintains sub-100µs latency by using compile-time dispatch (NO hash maps!)

const std = @import("std");
const proto = @import("proto.zig");

/// Service routing error
pub const RoutingError = error{
    ServiceNotFound,
    MethodNotFound,
    InvalidRoute,
};

/// Comptime service-to-handler mapping
pub fn GrpcServiceRegistry(comptime services: []const proto.ServiceMethod) type {
    // Validate service definitions at compile time
    comptime {
        if (services.len == 0) {
            @compileError("GrpcServiceRegistry requires at least one service");
        }

        // Check for duplicate service.method combinations
        for (services, 0..) |service_a, i| {
            for (services[i + 1 ..]) |service_b| {
                if (std.mem.eql(u8, service_a.service_name, service_b.service_name) and
                    std.mem.eql(u8, service_a.method_name, service_b.method_name))
                {
                    @compileError("Duplicate service.method found: " ++ service_a.service_name ++ "." ++ service_a.method_name);
                }
            }
        }

        // Check for duplicate MESSAGE_TYPE values (auto-validated at comptime)
        for (services, 0..) |service_a, i| {
            for (services[i + 1 ..]) |service_b| {
                if (service_a.message_type == service_b.message_type) {
                    @compileError("Duplicate MESSAGE_TYPE detected in gRPC services: " ++ service_a.service_name ++ "." ++ service_a.method_name ++ " and " ++ service_b.service_name ++ "." ++ service_b.method_name);
                }
            }
        }
    }

    return struct {
        const Self = @This();

        /// Route service.method to MESSAGE_TYPE (comptime dispatch)
        /// Returns null if service.method not found
        pub fn route(service: []const u8, method: []const u8) ?u8 {
            // Comptime-generated inline dispatch (becomes switch statement)
            inline for (services) |svc| {
                if (std.mem.eql(u8, service, svc.service_name) and
                    std.mem.eql(u8, method, svc.method_name))
                {
                    return svc.message_type;
                }
            }
            return null;
        }

        /// Get service name by MESSAGE_TYPE (reverse lookup)
        pub fn getServiceName(message_type: u8) ?[]const u8 {
            inline for (services) |svc| {
                if (svc.message_type == message_type) {
                    return svc.service_name;
                }
            }
            return null;
        }

        /// Get method name by MESSAGE_TYPE (reverse lookup)
        pub fn getMethodName(message_type: u8) ?[]const u8 {
            inline for (services) |svc| {
                if (svc.message_type == message_type) {
                    return svc.method_name;
                }
            }
            return null;
        }

        /// Get full route name (Service/Method format)
        pub fn getRouteName(message_type: u8, buffer: []u8) ?[]const u8 {
            inline for (services) |svc| {
                if (svc.message_type == message_type) {
                    return std.fmt.bufPrint(
                        buffer,
                        "{s}/{s}",
                        .{ svc.service_name, svc.method_name },
                    ) catch return null;
                }
            }
            return null;
        }

        /// Get count of registered services (comptime)
        pub fn getServiceCount() comptime_int {
            return services.len;
        }

        /// Get all service methods (comptime)
        pub fn getAllServices() []const proto.ServiceMethod {
            return services;
        }

        /// Validate that all message types are unique at compile time
        pub fn validateMessageTypes() void {
            comptime {
                for (services, 0..) |service_a, i| {
                    for (services[i + 1 ..]) |service_b| {
                        if (service_a.message_type == service_b.message_type) {
                            @compileError("Duplicate MESSAGE_TYPE detected in gRPC services");
                        }
                    }
                }
            }
        }
    };
}

// Compile-time tests
test "grpc service registry routing" {
    const test_services = [_]proto.ServiceMethod{
        .{ .service_name = "UserService", .method_name = "GetUser", .message_type = 10 },
        .{ .service_name = "UserService", .method_name = "ListUsers", .message_type = 11 },
        .{ .service_name = "PostService", .method_name = "CreatePost", .message_type = 20 },
        .{ .service_name = "PostService", .method_name = "DeletePost", .message_type = 21 },
    };

    const Registry = GrpcServiceRegistry(&test_services);

    // Test routing
    const msg_type_1 = Registry.route("UserService", "GetUser");
    try std.testing.expectEqual(@as(?u8, 10), msg_type_1);

    const msg_type_2 = Registry.route("PostService", "CreatePost");
    try std.testing.expectEqual(@as(?u8, 20), msg_type_2);

    const msg_type_3 = Registry.route("UnknownService", "UnknownMethod");
    try std.testing.expectEqual(@as(?u8, null), msg_type_3);

    // Test reverse lookup
    const service_name = Registry.getServiceName(11);
    try std.testing.expectEqualStrings("UserService", service_name.?);

    const method_name = Registry.getMethodName(21);
    try std.testing.expectEqualStrings("DeletePost", method_name.?);

    // Test route name
    var buffer: [128]u8 = undefined;
    const route_name = Registry.getRouteName(20, &buffer);
    try std.testing.expectEqualStrings("PostService/CreatePost", route_name.?);

    // Test count
    try std.testing.expectEqual(@as(comptime_int, 4), Registry.getServiceCount());
}

test "grpc service registry validation" {
    const test_services = [_]proto.ServiceMethod{
        .{ .service_name = "TestService", .method_name = "Method1", .message_type = 1 },
        .{ .service_name = "TestService", .method_name = "Method2", .message_type = 2 },
    };

    const Registry = GrpcServiceRegistry(&test_services);
    Registry.validateMessageTypes(); // Should compile successfully
}
