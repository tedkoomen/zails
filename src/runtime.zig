/// Public Zails runtime import surface.
///
/// Applications should depend on this module instead of importing framework
/// internals directly:
///
///   const zails = @import("zails");
///
///   const App = zails.App(.{
///       .handlers = .{ MyHandler },
///   });
///
///   pub const Registry = App.Registry;
const std = @import("std");

pub const result = @import("result");
pub const HandlerResponse = result.HandlerResponse;
pub const ServerError = result.ServerError;

pub const handler_interface = @import("handler_interface.zig");
pub const HandlerRegistry = @import("handler_registry.zig").HandlerRegistry;

pub const foreign = @import("foreign_handler.zig");
pub const NativeForeignHandler = foreign.NativeForeignHandler;
pub const NativeHandlerFn = foreign.NativeHandlerFn;
pub const CHandlerResult = foreign.CHandlerResult;
pub const nativeOk = foreign.nativeOk;
pub const nativeErr = foreign.nativeErr;
pub const TcpForeignHandler = foreign.TcpForeignHandler;
pub const TcpForeignSpec = foreign.TcpForeignSpec;
pub const ZailsProxyHandler = foreign.ZailsProxyHandler;
pub const ZailsProxySpec = foreign.ZailsProxySpec;

pub const local_ipc = @import("local_ipc.zig");

pub const message_bus = @import("message_bus/mod.zig");
pub const MessageBus = message_bus.MessageBus;
pub const Event = message_bus.Event;
pub const EventBuilder = message_bus.EventBuilder;
pub const Filter = message_bus.Filter;
pub const FixedString = message_bus.FixedString;

pub const reactive = @import("experimental/reactive_model.zig");
pub const ReactiveModel = reactive.ReactiveModel;
pub const ReactiveFieldType = reactive.FieldType;

pub const orm = @import("orm/mod.zig");
pub const proto = @import("proto.zig");
pub const grpc = struct {
    pub const registry = @import("grpc_registry.zig");
    pub const adapter = @import("grpc_handler_adapter.zig");
};

pub fn App(comptime spec: anytype) type {
    comptime {
        if (!@hasField(@TypeOf(spec), "handlers")) {
            @compileError("zails.App requires .handlers = .{ ... }");
        }
    }

    return struct {
        pub const handlers = spec.handlers;
        pub const Registry = HandlerRegistry(spec.handlers);

        pub fn init(allocator: std.mem.Allocator) !Registry {
            return Registry.init(allocator);
        }
    };
}

fn nativeReverse(
    request_ptr: [*]const u8,
    request_len: usize,
    response_ptr: [*]u8,
    response_cap: usize,
) callconv(.c) CHandlerResult {
    if (request_len > response_cap) return nativeErr(.message_too_large);

    const request = request_ptr[0..request_len];
    const response = response_ptr[0..request_len];
    for (request, 0..) |_, index| {
        response[index] = request[request_len - 1 - index];
    }
    return nativeOk(request_len);
}

test "runtime App exposes handler registry" {
    const NativeReverse = NativeForeignHandler(12, nativeReverse);
    const TestApp = App(.{ .handlers = .{NativeReverse} });

    var registry = try TestApp.init(std.testing.allocator);
    defer registry.deinit();

    var response_buffer: [32]u8 = undefined;
    const handler_result = registry.handle(12, "runtime", &response_buffer, std.testing.allocator);

    try std.testing.expect(handler_result.isOk());
    try std.testing.expectEqualStrings("emitnur", handler_result.data);
}
