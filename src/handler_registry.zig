/// Handler registry using comptime dispatch (NO VIRTUAL INHERITANCE, NO FUNCTION POINTERS!)
/// All dispatch happens at compile time via inline for loops
/// Tiger Style: NEVER THROWS - all errors are values

const std = @import("std");
const Allocator = std.mem.Allocator;
const result = @import("result");
const handler_interface = @import("handler_interface.zig");

/// Compile-time handler registration
/// Takes a tuple of handler modules and generates dispatch logic
pub fn HandlerRegistry(comptime handler_modules: anytype) type {
    // Validate all modules at compile time
    comptime {
        for (handler_modules) |module| {
            handler_interface.validateHandlerModule(module);
        }
    }

    return struct {
        const Self = @This();

        /// Storage for all handler contexts (one per module)
        /// This is a struct with fields for each handler's context
        // Pre-generate field names to avoid comptime evaluation limits
        const field_names = blk: {
            var names: [handler_modules.len][:0]const u8 = undefined;
            for (0..handler_modules.len) |i| {
                names[i] = std.fmt.comptimePrint("{d}", .{i});
            }
            break :blk names;
        };

        const Contexts = blk: {
            var fields: [handler_modules.len]std.builtin.Type.StructField = undefined;

            for (handler_modules, 0..) |module, i| {
                fields[i] = .{
                    .name = field_names[i],
                    .type = *module.Context,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(*module.Context),
                };
            }

            break :blk @Type(.{
                .@"struct" = .{
                    .layout = .auto,
                    .fields = &fields,
                    .decls = &.{},
                    .is_tuple = false,
                },
            });
        };

        allocator: Allocator,
        contexts: Contexts,

        pub fn init(allocator: Allocator) !Self {
            var self = Self{
                .allocator = allocator,
                .contexts = undefined,
            };

            // Runtime validation: check for duplicate MESSAGE_TYPE values
            var seen_types = std.StaticBitSet(256).initEmpty();
            inline for (handler_modules) |module| {
                if (seen_types.isSet(module.MESSAGE_TYPE)) {
                    std.log.err("Duplicate MESSAGE_TYPE {d} detected at runtime!", .{module.MESSAGE_TYPE});
                    return error.DuplicateMessageType;
                }
                seen_types.set(module.MESSAGE_TYPE);
            }

            // Initialize all handler contexts
            var initialized: usize = 0;
            errdefer {
                // Cleanup on error
                inline for (handler_modules, 0..) |_, i| {
                    if (i < initialized) {
                        const context_ptr = @field(self.contexts, field_names[i]);
                        context_ptr.deinit();
                        allocator.destroy(context_ptr);
                    }
                }
            }

            inline for (handler_modules, 0..) |module, i| {
                const context = try allocator.create(module.Context);
                context.* = module.Context.init();

                @field(self.contexts, field_names[i]) = context;

                initialized += 1;

                std.log.info("Registered handler: {s} (type {})", .{
                    @typeName(module),
                    module.MESSAGE_TYPE,
                });
            }

            return self;
        }

        /// Post-initialization hook - called after globals are set up
        /// Calls postInit() on handlers that have it
        pub fn postInit(self: *Self, allocator: Allocator) !void {
            inline for (handler_modules, 0..) |module, i| {
                const context_ptr = @field(self.contexts, field_names[i]);

                // Check if handler has postInit method
                if (@hasDecl(module.Context, "postInit")) {
                    try context_ptr.postInit(allocator);
                }
            }
        }

        pub fn deinit(self: *Self) void {
            inline for (handler_modules, 0..) |_, i| {
                const context_ptr = @field(self.contexts, field_names[i]);

                context_ptr.deinit();
                self.allocator.destroy(context_ptr);
            }
        }

        /// Handle a message (COMPTIME DISPATCH - NO VTABLE!)
        /// Tiger Style: NEVER THROWS - returns HandlerResponse
        pub fn handle(
            self: *Self,
            message_type: u8,
            request_data: []const u8,
            response_buffer: []u8,
            allocator: Allocator,
        ) result.HandlerResponse {
            // Compile-time dispatch using inline for
            // This generates a switch/if-else chain at compile time
            inline for (handler_modules, 0..) |module, i| {
                if (message_type == module.MESSAGE_TYPE) {
                    const context_ptr = @field(self.contexts, field_names[i]);

                    // DIRECT CALL to handler (can inline, NO vtable!)
                    // Handler NEVER throws - returns HandlerResponse
                    return module.handle(
                        context_ptr,
                        request_data,
                        response_buffer,
                        allocator,
                    );
                }
            }

            // No handler found - return error as value, not exception
            return result.HandlerResponse.err(.unknown_message_type);
        }

        /// Get count of registered handlers (comptime)
        pub fn getHandlerCount() comptime_int {
            return handler_modules.len;
        }

        /// Get list of all message types
        pub fn getAllMessageTypes() [handler_modules.len]u8 {
            var types: [handler_modules.len]u8 = undefined;
            inline for (handler_modules, 0..) |module, i| {
                types[i] = module.MESSAGE_TYPE;
            }
            return types;
        }
    };
}

// Compile-time tests
test "handler registry comptime" {
    // Example handler module - Tiger Style (never throws!)
    const TestHandler = struct {
        pub const MESSAGE_TYPE: u8 = 1;

        pub const Context = struct {
            value: u32,

            pub fn init() @This() {
                return .{ .value = 0 };
            }

            pub fn deinit(self: *@This()) void {
                _ = self;
            }
        };

        pub fn handle(
            ctx: *Context,
            request_data: []const u8,
            response_buffer: []u8,
            allocator: Allocator,
        ) result.HandlerResponse {
            _ = allocator;
            _ = request_data;
            ctx.value += 1;
            response_buffer[0] = @intCast(ctx.value);
            return result.HandlerResponse.ok(response_buffer[0..1]);
        }
    };

    const Registry = HandlerRegistry(.{TestHandler});

    const allocator = std.testing.allocator;
    var registry = try Registry.init(allocator);
    defer registry.deinit();

    var response: [64]u8 = undefined;
    const handler_result = registry.handle(1, &.{}, &response, allocator);

    try std.testing.expect(handler_result.isOk());
    try std.testing.expectEqual(@as(usize, 1), handler_result.data.len);
    try std.testing.expectEqual(@as(u8, 1), handler_result.data[0]);

    // Test unknown message type
    const unknown_result = registry.handle(99, &.{}, &response, allocator);
    try std.testing.expect(unknown_result.isErr());
    try std.testing.expectEqual(result.ServerError.unknown_message_type, unknown_result.error_code);
}
