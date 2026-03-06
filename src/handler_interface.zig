/// Tiger Style: Handler interface with errors as values
/// Handlers NEVER throw - all errors are returned as values

const std = @import("std");
const result = @import("result");
const Allocator = std.mem.Allocator;

/// Handler function signature - NO ERROR UNION!
/// Returns HandlerResponse with error_code instead of throwing
pub const HandlerFn = fn (
    context: *anyopaque,
    request_data: []const u8,
    response_buffer: []u8,
    allocator: Allocator,
) result.HandlerResponse;

/// Handler module requirements (checked at comptime)
pub fn validateHandlerModule(comptime Module: type) void {
    // Must export MESSAGE_TYPE
    if (!@hasDecl(Module, "MESSAGE_TYPE")) {
        @compileError(@typeName(Module) ++ " must export MESSAGE_TYPE: u8");
    }

    // Must export Context type
    if (!@hasDecl(Module, "Context")) {
        @compileError(@typeName(Module) ++ " must export Context type");
    }

    // Must export handle function with correct signature
    if (!@hasDecl(Module, "handle")) {
        @compileError(@typeName(Module) ++ " must export handle() function");
    }

    // Verify handle signature
    const handle_fn = @TypeOf(Module.handle);
    const expected_signature = fn (
        *Module.Context,
        []const u8,
        []u8,
        Allocator,
    ) result.HandlerResponse;

    if (handle_fn != expected_signature) {
        @compileError(@typeName(Module) ++ ".handle() must have signature: " ++
            "fn(*Context, []const u8, []u8, Allocator) HandlerResponse");
    }

    // Verify Context has init() and deinit()
    if (!@hasDecl(Module.Context, "init")) {
        @compileError(@typeName(Module.Context) ++ " must have init() function");
    }

    if (!@hasDecl(Module.Context, "deinit")) {
        @compileError(@typeName(Module.Context) ++ " must have deinit() function");
    }
}

/// Example handler module (for documentation)
pub const ExampleHandler = struct {
    pub const MESSAGE_TYPE: u8 = 255;

    pub const Context = struct {
        request_count: std.atomic.Value(u64),

        pub fn init() Context {
            return .{
                .request_count = std.atomic.Value(u64).init(0),
            };
        }

        pub fn deinit(self: *Context) void {
            _ = self;
        }
    };

    /// Tiger Style: Returns HandlerResponse, never throws!
    pub fn handle(
        context: *Context,
        request_data: []const u8,
        response_buffer: []u8,
        allocator: Allocator,
    ) result.HandlerResponse {
        _ = allocator;
        _ = context.request_count.fetchAdd(1, .monotonic);

        // Validate input
        if (request_data.len == 0) {
            return result.HandlerResponse.err(.malformed_message);
        }

        if (request_data.len > response_buffer.len) {
            return result.HandlerResponse.err(.message_too_large);
        }

        // Process request - NO TRY/CATCH!
        @memcpy(response_buffer[0..request_data.len], request_data);

        // Success - return value, not error union
        return result.HandlerResponse.ok(response_buffer[0..request_data.len]);
    }
};

// Verify example handler compiles
comptime {
    validateHandlerModule(ExampleHandler);
}
