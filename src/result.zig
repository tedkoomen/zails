/// Tiger Style: Errors as values, not exceptions
/// Inspired by TigerBeetle's coding philosophy
/// Request handling code NEVER throws - all errors are values

const std = @import("std");

/// Generic result type for operations that can fail
pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        ok: T,
        err: E,

        pub fn isOk(self: @This()) bool {
            return self == .ok;
        }

        pub fn isErr(self: @This()) bool {
            return self == .err;
        }

        pub fn unwrap(self: @This()) T {
            return switch (self) {
                .ok => |val| val,
                .err => unreachable, // Caller must check isOk() first
            };
        }

        pub fn unwrapOr(self: @This(), default: T) T {
            return switch (self) {
                .ok => |val| val,
                .err => default,
            };
        }

        pub fn unwrapErr(self: @This()) E {
            return switch (self) {
                .err => |e| e,
                .ok => unreachable, // Caller must check isErr() first
            };
        }

        /// Map the success value to a different type
        pub fn map(self: @This(), comptime U: type, func: fn (T) U) Result(U, E) {
            return switch (self) {
                .ok => |val| .{ .ok = func(val) },
                .err => |e| .{ .err = e },
            };
        }

        /// Map the error value to a different type
        pub fn mapErr(self: @This(), comptime F: type, func: fn (E) F) Result(T, F) {
            return switch (self) {
                .ok => |val| .{ .ok = val },
                .err => |e| .{ .err = func(e) },
            };
        }
    };
}

/// Common errors in the server
pub const ServerError = enum(u8) {
    none = 0,

    // Connection errors
    connection_closed = 1,
    connection_timeout = 2,
    connection_limit_reached = 3,

    // Protocol errors
    invalid_header = 10,
    message_too_large = 11,
    malformed_message = 12,
    unknown_message_type = 13,

    // Resource errors
    pool_exhausted = 20,
    queue_full = 21,
    out_of_memory = 22,

    // Handler errors
    handler_not_found = 30,
    handler_failed = 31,
    handler_timeout = 32,

    // IO errors
    read_failed = 40,
    write_failed = 41,

    pub fn toString(self: ServerError) []const u8 {
        return switch (self) {
            .none => "no error",
            .connection_closed => "connection closed",
            .connection_timeout => "connection timeout",
            .connection_limit_reached => "connection limit reached",
            .invalid_header => "invalid message header",
            .message_too_large => "message too large",
            .malformed_message => "malformed message",
            .unknown_message_type => "unknown message type",
            .pool_exhausted => "object pool exhausted",
            .queue_full => "work queue full",
            .out_of_memory => "out of memory",
            .handler_not_found => "handler not found",
            .handler_failed => "handler failed",
            .handler_timeout => "handler timeout",
            .read_failed => "read operation failed",
            .write_failed => "write operation failed",
        };
    }
};

/// Response type for message handlers
pub const HandlerResponse = struct {
    data: []const u8,
    error_code: ServerError,

    pub fn ok(data: []const u8) HandlerResponse {
        return .{
            .data = data,
            .error_code = .none,
        };
    }

    pub fn err(error_code: ServerError) HandlerResponse {
        return .{
            .data = &.{},
            .error_code = error_code,
        };
    }

    pub fn isOk(self: HandlerResponse) bool {
        return self.error_code == .none;
    }

    pub fn isErr(self: HandlerResponse) bool {
        return self.error_code != .none;
    }
};

/// Message parsing result
pub const MessageParseResult = struct {
    msg_type: u8,
    data: []const u8,
    error_code: ServerError,

    pub fn ok(msg_type: u8, data: []const u8) MessageParseResult {
        return .{
            .msg_type = msg_type,
            .data = data,
            .error_code = .none,
        };
    }

    pub fn err(error_code: ServerError) MessageParseResult {
        return .{
            .msg_type = 0,
            .data = &.{},
            .error_code = error_code,
        };
    }

    pub fn isOk(self: MessageParseResult) bool {
        return self.error_code == .none;
    }
};

/// IO operation result
pub const IOResult = struct {
    bytes: usize,
    error_code: ServerError,

    pub fn ok(bytes: usize) IOResult {
        return .{
            .bytes = bytes,
            .error_code = .none,
        };
    }

    pub fn err(error_code: ServerError) IOResult {
        return .{
            .bytes = 0,
            .error_code = error_code,
        };
    }

    pub fn isOk(self: IOResult) bool {
        return self.error_code == .none;
    }

    pub fn isEof(self: IOResult) bool {
        return self.bytes == 0 and self.error_code == .none;
    }
};

// Tests
test "Result ok/err" {
    const TestResult = Result(u32, ServerError);

    const ok_val = TestResult{ .ok = 42 };
    try std.testing.expect(ok_val.isOk());
    try std.testing.expectEqual(@as(u32, 42), ok_val.unwrap());

    const err_val = TestResult{ .err = .pool_exhausted };
    try std.testing.expect(err_val.isErr());
    try std.testing.expectEqual(ServerError.pool_exhausted, err_val.unwrapErr());
}

test "HandlerResponse" {
    const ok_response = HandlerResponse.ok("test");
    try std.testing.expect(ok_response.isOk());
    try std.testing.expectEqualStrings("test", ok_response.data);

    const err_response = HandlerResponse.err(.handler_failed);
    try std.testing.expect(err_response.isErr());
    try std.testing.expectEqual(ServerError.handler_failed, err_response.error_code);
}
