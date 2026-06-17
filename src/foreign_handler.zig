/// Foreign handler support for non-Zig application code.
///
/// Two integration modes are intentionally separate:
/// - NativeForeignHandler wraps C-ABI functions that are linked into the Zails
///   binary. This is the path for C, C++, Rust `extern "C"`, Zig plugins, and
///   other compiled languages that can be baked into the executable.
/// - TcpForeignHandler speaks a small fixed-header protocol to an out-of-process
///   worker. This is the path for Python, Ruby, Node, Java, and anything else
///   that should live outside the Zails process.
///
/// ZailsProxyHandler is for runtime-to-runtime calls. It targets another Zails
/// server and uses the local IPC registrar/ring buffer when the destination is
/// on the same machine.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const result = @import("result");
const local_ipc = @import("local_ipc.zig");

pub const MAX_FRAME_PAYLOAD_BYTES: usize = local_ipc.SLOT_PAYLOAD_BYTES;
pub const FRAME_HEADER_BYTES: usize = 32;
pub const FRAME_MAGIC: u32 = 0x31_46_48_5a; // Wire bytes: "ZHF1".
pub const FRAME_VERSION: u16 = 1;
pub const DEFAULT_FOREIGN_TIMEOUT_US: u64 = 2_000_000;

pub const FrameError = error{
    BufferTooSmall,
    PayloadTooLarge,
    InvalidMagic,
    InvalidVersion,
    InvalidFrameKind,
    IncompleteFrame,
};

pub const FrameKind = enum(u8) {
    request = 1,
    response = 2,
    health = 3,
};

pub const Frame = struct {
    kind: FrameKind,
    request_id: u64,
    message_type: u8,
    error_code: result.ServerError = .none,
    payload: []const u8,
};

pub fn encodeFrame(frame: Frame, out: []u8) FrameError![]const u8 {
    if (frame.payload.len > MAX_FRAME_PAYLOAD_BYTES) return error.PayloadTooLarge;

    const total_len = FRAME_HEADER_BYTES + frame.payload.len;
    if (out.len < total_len) return error.BufferTooSmall;

    @memset(out[0..FRAME_HEADER_BYTES], 0);
    std.mem.writeInt(u32, out[0..4], FRAME_MAGIC, .little);
    std.mem.writeInt(u16, out[4..6], FRAME_VERSION, .little);
    out[6] = @intFromEnum(frame.kind);
    out[7] = 0;
    std.mem.writeInt(u64, out[8..16], frame.request_id, .little);
    out[16] = frame.message_type;
    out[17] = @intFromEnum(frame.error_code);
    std.mem.writeInt(u16, out[18..20], 0, .little);
    std.mem.writeInt(u32, out[20..24], @as(u32, @intCast(frame.payload.len)), .little);
    std.mem.writeInt(u64, out[24..32], 0, .little);
    @memcpy(out[FRAME_HEADER_BYTES..total_len], frame.payload);

    return out[0..total_len];
}

pub fn decodeFrame(bytes: []const u8) FrameError!Frame {
    if (bytes.len < FRAME_HEADER_BYTES) return error.IncompleteFrame;

    const magic = std.mem.readInt(u32, bytes[0..4], .little);
    if (magic != FRAME_MAGIC) return error.InvalidMagic;

    const version = std.mem.readInt(u16, bytes[4..6], .little);
    if (version != FRAME_VERSION) return error.InvalidVersion;

    const kind = std.meta.intToEnum(FrameKind, bytes[6]) catch return error.InvalidFrameKind;
    const payload_len = std.mem.readInt(u32, bytes[20..24], .little);
    if (payload_len > MAX_FRAME_PAYLOAD_BYTES) return error.PayloadTooLarge;

    const total_len = FRAME_HEADER_BYTES + @as(usize, @intCast(payload_len));
    if (bytes.len < total_len) return error.IncompleteFrame;

    const server_error = std.meta.intToEnum(result.ServerError, bytes[17]) catch .handler_failed;
    return .{
        .kind = kind,
        .request_id = std.mem.readInt(u64, bytes[8..16], .little),
        .message_type = bytes[16],
        .error_code = server_error,
        .payload = bytes[FRAME_HEADER_BYTES..total_len],
    };
}

pub fn encodeRequest(message_type: u8, request_id: u64, payload: []const u8, out: []u8) FrameError![]const u8 {
    return encodeFrame(.{
        .kind = .request,
        .request_id = request_id,
        .message_type = message_type,
        .payload = payload,
    }, out);
}

pub fn encodeResponse(
    message_type: u8,
    request_id: u64,
    error_code: result.ServerError,
    payload: []const u8,
    out: []u8,
) FrameError![]const u8 {
    return encodeFrame(.{
        .kind = .response,
        .request_id = request_id,
        .message_type = message_type,
        .error_code = error_code,
        .payload = payload,
    }, out);
}

pub const CHandlerResult = extern struct {
    len: usize,
    error_code: u8,
};

pub const NativeHandlerFn = *const fn (
    request_ptr: [*]const u8,
    request_len: usize,
    response_ptr: [*]u8,
    response_cap: usize,
) callconv(.c) CHandlerResult;

pub fn nativeOk(len: usize) CHandlerResult {
    return .{ .len = len, .error_code = @intFromEnum(result.ServerError.none) };
}

pub fn nativeErr(error_code: result.ServerError) CHandlerResult {
    return .{ .len = 0, .error_code = @intFromEnum(error_code) };
}

pub fn NativeForeignHandler(comptime message_type: u8, comptime native_handler: NativeHandlerFn) type {
    return struct {
        pub const MESSAGE_TYPE: u8 = message_type;

        pub const Context = struct {
            pub fn init() Context {
                return .{};
            }

            pub fn deinit(self: *Context) void {
                _ = self;
            }
        };

        pub fn handle(
            context: *Context,
            request_data: []const u8,
            response_buffer: []u8,
            allocator: Allocator,
        ) result.HandlerResponse {
            _ = context;
            _ = allocator;

            const native_result = native_handler(
                request_data.ptr,
                request_data.len,
                response_buffer.ptr,
                response_buffer.len,
            );
            const error_code = std.meta.intToEnum(result.ServerError, native_result.error_code) catch .handler_failed;
            if (error_code != .none) return result.HandlerResponse.err(error_code);
            if (native_result.len > response_buffer.len) return result.HandlerResponse.err(.message_too_large);

            return result.HandlerResponse.ok(response_buffer[0..native_result.len]);
        }
    };
}

pub const TcpForeignSpec = struct {
    message_type: u8,
    host: []const u8 = "127.0.0.1",
    port: u16,
    target_message_type: ?u8 = null,
    timeout_us: u64 = DEFAULT_FOREIGN_TIMEOUT_US,
};

pub fn TcpForeignHandler(comptime spec: TcpForeignSpec) type {
    return struct {
        pub const MESSAGE_TYPE: u8 = spec.message_type;

        pub const Context = struct {
            next_request_id: std.atomic.Value(u64),

            pub fn init() Context {
                return .{ .next_request_id = std.atomic.Value(u64).init(1) };
            }

            pub fn deinit(self: *Context) void {
                _ = self;
            }
        };

        pub fn handle(
            context: *Context,
            request_data: []const u8,
            response_buffer: []u8,
            allocator: Allocator,
        ) result.HandlerResponse {
            if (request_data.len > MAX_FRAME_PAYLOAD_BYTES) return result.HandlerResponse.err(.message_too_large);

            var request_frame_buffer: [FRAME_HEADER_BYTES + MAX_FRAME_PAYLOAD_BYTES]u8 = undefined;
            const request_id = context.next_request_id.fetchAdd(1, .monotonic);
            const target_message_type = spec.target_message_type orelse spec.message_type;
            const request_frame = encodeRequest(
                target_message_type,
                request_id,
                request_data,
                &request_frame_buffer,
            ) catch return result.HandlerResponse.err(.message_too_large);

            const address = resolveTcpAddress(allocator, spec.host, spec.port) catch {
                return result.HandlerResponse.err(.handler_failed);
            };
            const deadline_ns = makeDeadlineNs(spec.timeout_us);
            const stream = connectTcpWithDeadline(address, deadline_ns) catch {
                return result.HandlerResponse.err(.connection_timeout);
            };
            defer stream.close();

            writeAllWithDeadline(stream, request_frame, deadline_ns) catch |err| switch (err) {
                error.TimedOut => return result.HandlerResponse.err(.handler_timeout),
                else => return result.HandlerResponse.err(.write_failed),
            };

            var header: [FRAME_HEADER_BYTES]u8 = undefined;
            readExactlyWithDeadline(stream, &header, deadline_ns) catch |err| switch (err) {
                error.TimedOut => return result.HandlerResponse.err(.handler_timeout),
                else => return result.HandlerResponse.err(.read_failed),
            };

            const payload_len = validateHeaderAndPayloadLen(&header) catch return result.HandlerResponse.err(.malformed_message);
            if (payload_len > response_buffer.len) return result.HandlerResponse.err(.message_too_large);

            readExactlyWithDeadline(stream, response_buffer[0..payload_len], deadline_ns) catch |err| switch (err) {
                error.TimedOut => return result.HandlerResponse.err(.handler_timeout),
                else => return result.HandlerResponse.err(.read_failed),
            };

            var full_header: [FRAME_HEADER_BYTES + MAX_FRAME_PAYLOAD_BYTES]u8 = undefined;
            @memcpy(full_header[0..FRAME_HEADER_BYTES], &header);
            @memcpy(full_header[FRAME_HEADER_BYTES .. FRAME_HEADER_BYTES + payload_len], response_buffer[0..payload_len]);
            const response_frame = decodeFrame(full_header[0 .. FRAME_HEADER_BYTES + payload_len]) catch {
                return result.HandlerResponse.err(.malformed_message);
            };

            if (response_frame.kind != .response) return result.HandlerResponse.err(.malformed_message);
            if (response_frame.request_id != request_id) return result.HandlerResponse.err(.malformed_message);
            if (response_frame.error_code != .none) return result.HandlerResponse.err(response_frame.error_code);

            return result.HandlerResponse.ok(response_buffer[0..payload_len]);
        }
    };
}

fn makeDeadlineNs(timeout_us: u64) i128 {
    const effective_timeout_us = if (timeout_us == 0) DEFAULT_FOREIGN_TIMEOUT_US else timeout_us;
    return std.time.nanoTimestamp() + (@as(i128, @intCast(effective_timeout_us)) * std.time.ns_per_us);
}

fn remainingTimeoutMs(deadline_ns: i128) !i32 {
    const remaining_ns = deadline_ns - std.time.nanoTimestamp();
    if (remaining_ns <= 0) return error.TimedOut;

    const rounded_ms = @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    return @intCast(@min(rounded_ms, std.math.maxInt(i32)));
}

fn waitForFd(handle: std.net.Stream.Handle, events: i16, deadline_ns: i128) !void {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = handle,
        .events = events,
        .revents = 0,
    }};

    while (true) {
        poll_fds[0].revents = 0;
        const ready = try std.posix.poll(&poll_fds, try remainingTimeoutMs(deadline_ns));
        if (ready == 0) return error.TimedOut;

        const revents = poll_fds[0].revents;
        if ((revents & events) != 0) return;
        if ((revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) {
            return error.SocketNotReady;
        }
    }
}

fn connectTcpWithDeadline(address: std.net.Address, deadline_ns: i128) !std.net.Stream {
    const sock_flags = std.posix.SOCK.STREAM |
        std.posix.SOCK.NONBLOCK |
        (if (builtin.os.tag == .windows) 0 else std.posix.SOCK.CLOEXEC);
    const sockfd = try std.posix.socket(address.any.family, sock_flags, std.posix.IPPROTO.TCP);
    errdefer std.posix.close(sockfd);

    std.posix.connect(sockfd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {},
        else => return err,
    };

    try waitForFd(sockfd, std.posix.POLL.OUT, deadline_ns);
    try std.posix.getsockoptError(sockfd);

    return .{ .handle = sockfd };
}

fn writeAllWithDeadline(stream: std.net.Stream, buffer: []const u8, deadline_ns: i128) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        try waitForFd(stream.handle, std.posix.POLL.OUT, deadline_ns);
        const written = stream.write(buffer[offset..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (written == 0) return error.EndOfStream;
        offset += written;
    }
}

fn readExactlyWithDeadline(stream: std.net.Stream, buffer: []u8, deadline_ns: i128) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        try waitForFd(stream.handle, std.posix.POLL.IN, deadline_ns);
        const read_len = stream.read(buffer[offset..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (read_len == 0) return error.EndOfStream;
        offset += read_len;
    }
}

pub const ZailsProxySpec = struct {
    message_type: u8,
    host: []const u8 = "127.0.0.1",
    port: u16,
    target_message_type: ?u8 = null,
    timeout_us: u64 = local_ipc.DEFAULT_TIMEOUT_US,
};

pub fn ZailsProxyHandler(comptime spec: ZailsProxySpec) type {
    return struct {
        pub const MESSAGE_TYPE: u8 = spec.message_type;

        pub const Context = struct {
            pub fn init() Context {
                return .{};
            }

            pub fn deinit(self: *Context) void {
                _ = self;
            }
        };

        pub fn handle(
            context: *Context,
            request_data: []const u8,
            response_buffer: []u8,
            allocator: Allocator,
        ) result.HandlerResponse {
            _ = context;

            const target_message_type = spec.target_message_type orelse spec.message_type;
            const response = local_ipc.tryRequest(
                allocator,
                spec.host,
                spec.port,
                target_message_type,
                request_data,
                response_buffer,
                spec.timeout_us,
                null,
            ) catch return result.HandlerResponse.err(.handler_failed);

            if (response) |payload| return result.HandlerResponse.ok(payload);
            return result.HandlerResponse.err(.handler_not_found);
        }
    };
}

fn resolveTcpAddress(allocator: Allocator, host: []const u8, port: u16) !std.net.Address {
    if (std.net.Address.parseIp(host, port)) |address| return address else |_| {}

    var address_list = try std.net.getAddressList(allocator, host, port);
    defer address_list.deinit();
    if (address_list.addrs.len == 0) return error.UnknownHostName;
    return address_list.addrs[0];
}

fn validateHeaderAndPayloadLen(header: []const u8) FrameError!usize {
    if (header.len < FRAME_HEADER_BYTES) return error.IncompleteFrame;
    if (std.mem.readInt(u32, header[0..4], .little) != FRAME_MAGIC) return error.InvalidMagic;
    if (std.mem.readInt(u16, header[4..6], .little) != FRAME_VERSION) return error.InvalidVersion;
    _ = std.meta.intToEnum(FrameKind, header[6]) catch return error.InvalidFrameKind;
    const payload_len = std.mem.readInt(u32, header[20..24], .little);
    if (payload_len > MAX_FRAME_PAYLOAD_BYTES) return error.PayloadTooLarge;
    return @intCast(payload_len);
}

fn nativeUppercase(
    request_ptr: [*]const u8,
    request_len: usize,
    response_ptr: [*]u8,
    response_cap: usize,
) callconv(.c) CHandlerResult {
    if (request_len > response_cap) return nativeErr(.message_too_large);
    const request = request_ptr[0..request_len];
    const response = response_ptr[0..request_len];
    for (request, 0..) |byte, index| {
        response[index] = std.ascii.toUpper(byte);
    }
    return nativeOk(request_len);
}

test "foreign frame request round trip" {
    var buffer: [FRAME_HEADER_BYTES + 64]u8 = undefined;
    const encoded = try encodeRequest(42, 99, "hello", &buffer);
    const decoded = try decodeFrame(encoded);

    try std.testing.expectEqual(FrameKind.request, decoded.kind);
    try std.testing.expectEqual(@as(u64, 99), decoded.request_id);
    try std.testing.expectEqual(@as(u8, 42), decoded.message_type);
    try std.testing.expectEqual(result.ServerError.none, decoded.error_code);
    try std.testing.expectEqualStrings("hello", decoded.payload);
}

test "foreign frame response carries handler error as value" {
    var buffer: [FRAME_HEADER_BYTES]u8 = undefined;
    const encoded = try encodeResponse(7, 11, .handler_failed, "", &buffer);
    const decoded = try decodeFrame(encoded);

    try std.testing.expectEqual(FrameKind.response, decoded.kind);
    try std.testing.expectEqual(@as(u64, 11), decoded.request_id);
    try std.testing.expectEqual(result.ServerError.handler_failed, decoded.error_code);
    try std.testing.expectEqual(@as(usize, 0), decoded.payload.len);
}

test "native foreign handler adapts C ABI function to HandlerResponse" {
    const Handler = NativeForeignHandler(77, nativeUppercase);
    var context = Handler.Context.init();
    defer context.deinit();

    var response_buffer: [32]u8 = undefined;
    const handler_result = Handler.handle(&context, "zails", &response_buffer, std.testing.allocator);

    try std.testing.expect(handler_result.isOk());
    try std.testing.expectEqualStrings("ZAILS", handler_result.data);
}

test "native foreign handler maps C ABI error code" {
    const Handler = NativeForeignHandler(77, nativeUppercase);
    var context = Handler.Context.init();
    defer context.deinit();

    var response_buffer: [2]u8 = undefined;
    const handler_result = Handler.handle(&context, "zails", &response_buffer, std.testing.allocator);

    try std.testing.expect(handler_result.isErr());
    try std.testing.expectEqual(result.ServerError.message_too_large, handler_result.error_code);
}

test "tcp foreign handler times out when worker accepts but stalls" {
    const port: u16 = 39194;
    const Handler = TcpForeignHandler(.{
        .message_type = 88,
        .host = "127.0.0.1",
        .port = port,
        .timeout_us = 30_000,
    });

    const address = try std.net.Address.parseIp("127.0.0.1", port);
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    const StallServer = struct {
        fn run(server: *std.net.Server) void {
            const connection = server.accept() catch return;
            defer connection.stream.close();
            std.Thread.sleep(150 * std.time.ns_per_ms);
        }
    };

    const server_thread = try std.Thread.spawn(.{}, StallServer.run, .{&listener});
    defer server_thread.join();

    var context = Handler.Context.init();
    defer context.deinit();

    var response_buffer: [64]u8 = undefined;
    const handler_result = Handler.handle(&context, "hello", &response_buffer, std.testing.allocator);

    try std.testing.expect(handler_result.isErr());
    try std.testing.expectEqual(result.ServerError.handler_timeout, handler_result.error_code);
}
