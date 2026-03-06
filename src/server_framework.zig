/// Core server framework - minimal, no business logic
/// Uses comptime handler registry (NO mutexes, NO virtual inheritance)
/// Tiger Style: Request handling NEVER THROWS - all errors are values

const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;
const result = @import("result");
const globals = @import("root").globals;
const async_clickhouse = @import("async_clickhouse.zig");

/// Message type identifier
pub const MessageType = u8;

/// Maximum message size (16MB)
pub const MAX_MESSAGE_SIZE: u32 = 16 * 1024 * 1024;

/// Connection timeout in milliseconds (reduced to 2s to prevent worker starvation)
pub const CONNECTION_TIMEOUT_MS = 2_000;

const ReadState = enum {
    reading_header,
    reading_body,
};

/// Tiger Style: Read from connection - returns IOResult, never throws
fn readExact(stream: net.Stream, buffer: []u8) result.IOResult {
    var pos: usize = 0;
    while (pos < buffer.len) {
        const bytes_read = stream.read(buffer[pos..]) catch {
            return result.IOResult.err(.read_failed);
        };

        if (bytes_read == 0) {
            // EOF
            if (pos == 0) {
                return result.IOResult.ok(0); // Clean EOF
            } else {
                return result.IOResult.err(.connection_closed); // Partial read
            }
        }

        pos += bytes_read;
    }
    return result.IOResult.ok(pos);
}

/// Tiger Style: Write all data - returns IOResult, never throws
fn writeAll(stream: net.Stream, data: []const u8) result.IOResult {
    stream.writeAll(data) catch {
        return result.IOResult.err(.write_failed);
    };
    return result.IOResult.ok(data.len);
}

/// Generic connection handler that dispatches to registry
/// Tiger Style: This function NEVER THROWS - all errors are handled as values
pub fn handleConnection(
    connection: net.Server.Connection,
    registry: anytype, // Generic over any HandlerRegistry type
) void {
    defer connection.stream.close();

    // Use arena allocator for handler allocations (zero-cost cleanup)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Stack buffers for common case
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;

    // State machine for protocol handling
    var state: ReadState = .reading_header;
    var header: [5]u8 = undefined;
    var header_pos: usize = 0;
    var msg_type: MessageType = 0;
    var message_length: u32 = 0;
    var body_pos: usize = 0;

    // Dynamic buffer for large messages — use page_allocator directly
    // (arena.free() is a no-op, so large buffers would leak on long connections)
    var large_buffer: ?[]u8 = null;
    defer if (large_buffer) |buf| std.heap.page_allocator.free(buf);

    var idle_start = std.time.milliTimestamp();

    // Tiger Style: Main loop NEVER THROWS - all errors handled as values
    while (true) {
        // Check for idle timeout
        const now = std.time.milliTimestamp();
        if (now - idle_start > CONNECTION_TIMEOUT_MS) {
            std.log.debug("Connection timeout", .{});
            return;
        }

        switch (state) {
            .reading_header => {
                // Read remaining header bytes - NO TRY!
                const read_result = readExact(
                    connection.stream,
                    header[header_pos..],
                );

                if (!read_result.isOk() or read_result.isEof()) {
                    // Error or EOF - exit cleanly
                    return;
                }

                header_pos += read_result.bytes;

                if (header_pos >= 5) {
                    // Full header received
                    msg_type = header[0];
                    message_length = std.mem.readInt(u32, header[1..5], .big);

                    // Validate message size
                    if (message_length > MAX_MESSAGE_SIZE) {
                        std.log.warn("Message too large: {} (max: {})", .{ message_length, MAX_MESSAGE_SIZE });
                        return; // Close connection
                    }

                    // Allocate large buffer if needed - NO TRY!
                    // Use page_allocator directly so free() actually reclaims memory
                    if (message_length > read_buffer.len) {
                        large_buffer = std.heap.page_allocator.alloc(u8, message_length) catch null;
                        if (large_buffer == null) {
                            std.log.err("Failed to allocate {} bytes", .{message_length});
                            return;
                        }
                    }

                    state = .reading_body;
                    body_pos = 0;
                    header_pos = 0; // Reset for next message
                }
            },

            .reading_body => {
                const target_buffer = if (large_buffer) |buf| buf else read_buffer[0..message_length];

                // Read message body - NO TRY!
                const read_result = readExact(
                    connection.stream,
                    target_buffer[body_pos..],
                );

                if (!read_result.isOk() or read_result.isEof()) {
                    return;
                }

                body_pos += read_result.bytes;

                if (body_pos >= message_length) {
                    // Full message received - reset idle timer
                    idle_start = std.time.milliTimestamp();

                    // Start timing for latency tracking
                    const request_start_ns = std.time.nanoTimestamp();

                    // Dispatch to handler - NO TRY! Handler returns value, not error
                    const request_data = target_buffer[0..message_length];
                    const handler_response = registry.handle(
                        msg_type,
                        request_data,
                        &write_buffer,
                        allocator,
                    );

                    // Calculate latency (guard against clock skew)
                    const request_end_ns = std.time.nanoTimestamp();
                    const elapsed_ns = request_end_ns - request_start_ns;
                    const latency_us: u64 = if (elapsed_ns > 0) @intCast(@divTrunc(elapsed_ns, 1000)) else 0;

                    // Record metrics to ClickHouse if enabled
                    if (globals.global_clickhouse) |clickhouse_writer| {
                        recordRequestMetric(
                            clickhouse_writer,
                            msg_type,
                            request_data,
                            handler_response,
                            connection,
                            latency_us,
                        );
                    }

                    // Check handler result - error as value, not exception
                    if (!handler_response.isOk()) {
                        std.log.debug("Handler failed: {s}", .{handler_response.error_code.toString()});
                        state = .reading_header;
                        continue;
                    }

                    // Validate response size
                    const response_data = handler_response.data;
                    if (response_data.len > MAX_MESSAGE_SIZE) {
                        std.log.err("Response too large: {}", .{response_data.len});
                        return;
                    }

                    // Write response header: [1 byte: type] [4 bytes: length]
                    var response_header: [5]u8 = undefined;
                    response_header[0] = msg_type;
                    std.mem.writeInt(u32, response_header[1..5], @as(u32, @intCast(response_data.len)), .big);

                    // Write header - NO TRY!
                    const write_header_result = writeAll(connection.stream, &response_header);
                    if (!write_header_result.isOk()) {
                        std.log.debug("Write error: {s}", .{write_header_result.error_code.toString()});
                        return;
                    }

                    // Write response body - NO TRY!
                    const write_body_result = writeAll(connection.stream, response_data);
                    if (!write_body_result.isOk()) {
                        std.log.debug("Write error: {s}", .{write_body_result.error_code.toString()});
                        return;
                    }

                    // Clean up large buffer for next message
                    if (large_buffer) |buf| {
                        std.heap.page_allocator.free(buf);
                        large_buffer = null;
                    }

                    // Reset for next message
                    state = .reading_header;
                    body_pos = 0;
                }
            },
        }
    }
}

/// Thread-local worker ID for metric tracking
threadlocal var current_worker_id: u16 = 0;

pub fn setWorkerID(id: u16) void {
    current_worker_id = id;
}

/// Record request metrics to ClickHouse
fn recordRequestMetric(
    clickhouse_writer: *async_clickhouse.AsyncClickHouseWriter,
    message_type: u8,
    request_data: []const u8,
    handler_response: result.HandlerResponse,
    connection: net.Server.Connection,
    latency_us: u64,
) void {
    // Generate UUID for request
    var request_id: [16]u8 = undefined;
    std.crypto.random.bytes(&request_id);

    // Get client IP and port (handle both IPv4 and IPv6)
    var client_ip: u32 = 0;
    var client_port: u16 = 0;
    switch (connection.address.any.family) {
        std.posix.AF.INET => {
            const addr4 = connection.address.in;
            client_ip = @bitCast(addr4.sa.addr);
            client_port = std.mem.bigToNative(u16, addr4.sa.port);
        },
        std.posix.AF.INET6 => {
            const addr6 = connection.address.in6;
            client_port = std.mem.bigToNative(u16, addr6.sa.port);
            // Store last 4 bytes of IPv6 address for metrics (best effort)
            client_ip = @bitCast(addr6.sa.addr[12..16].*);
        },
        else => {},
    }

    // Determine error code
    const error_code: u8 = if (handler_response.isOk()) 0 else @intFromEnum(handler_response.error_code);

    // Build error message
    var error_message: [256]u8 = [_]u8{0} ** 256;
    if (!handler_response.isOk()) {
        const err_msg = handler_response.error_code.toString();
        const len = @min(err_msg.len, error_message.len - 1);
        @memcpy(error_message[0..len], err_msg[0..len]);
    }

    // Get handler name (placeholder - could be enhanced with registry lookup)
    var handler_name: [64]u8 = [_]u8{0} ** 64;
    _ = std.fmt.bufPrint(&handler_name, "handler_{d}", .{message_type}) catch {};

    // Get server instance (hostname or process ID)
    var server_instance: [64]u8 = [_]u8{0} ** 64;
    // Use cross-platform getpid() instead of Linux-specific version
    const pid = if (@hasDecl(std.os, "linux"))
        std.os.linux.getpid()
    else
        std.c.getpid();
    _ = std.fmt.bufPrint(&server_instance, "pid_{d}", .{pid}) catch {};

    // Capture payload samples (first 256 bytes)
    var request_sample: [256]u8 = [_]u8{0} ** 256;
    var response_sample: [256]u8 = [_]u8{0} ** 256;
    const capture_payload = false; // TODO: Make this configurable per-handler

    if (capture_payload) {
        const req_len = @min(request_data.len, request_sample.len);
        @memcpy(request_sample[0..req_len], request_data[0..req_len]);

        if (handler_response.isOk()) {
            const resp_len = @min(handler_response.data.len, response_sample.len);
            @memcpy(response_sample[0..resp_len], handler_response.data[0..resp_len]);
        }
    }

    // Build metric row
    const metric = async_clickhouse.MetricRow{
        .timestamp = @divTrunc(std.time.milliTimestamp(), 1000), // Convert to seconds
        .request_id = request_id,
        .message_type = message_type,
        .handler_name = handler_name,
        .latency_us = latency_us,
        .request_size = @as(u32, @intCast(request_data.len)),
        .response_size = if (handler_response.isOk()) @as(u32, @intCast(handler_response.data.len)) else 0,
        .client_ip = client_ip,
        .client_port = client_port,
        .worker_id = current_worker_id,
        .error_code = error_code,
        .error_message = error_message,
        .server_instance = server_instance,
        .request_sample = request_sample,
        .response_sample = response_sample,
        .capture_payload = capture_payload,
    };

    // Record metric (non-blocking, fire-and-forget)
    clickhouse_writer.recordMetric(metric);
}
