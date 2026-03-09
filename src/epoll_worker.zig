/// Event-driven worker using epoll for multiplexing thousands of connections
/// Each worker manages its own epoll instance and connection state

const std = @import("std");
const net = std.net;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const server_framework = @import("server_framework.zig");

pub const ConnectionState = enum {
    reading_header,
    reading_body,
    processing,
    writing_response,
    closing,
};

pub const Connection = struct {
    fd: std.posix.fd_t,
    state: ConnectionState,
    last_activity: i64,

    // Protocol state
    header: [5]u8,
    header_pos: usize,
    msg_type: u8,
    message_length: u32,
    body_pos: usize,

    // Buffers
    read_buffer: [8192]u8,
    write_buffer: [8192]u8,
    write_pos: usize,
    write_len: usize,

    // Large message support
    large_buffer: ?[]u8,

    fn init(fd: std.posix.fd_t) Connection {
        return .{
            .fd = fd,
            .state = .reading_header,
            .last_activity = std.time.milliTimestamp(),
            .header = undefined,
            .header_pos = 0,
            .msg_type = 0,
            .message_length = 0,
            .body_pos = 0,
            .read_buffer = undefined,
            .write_buffer = undefined,
            .write_pos = 0,
            .write_len = 0,
            .large_buffer = null,
        };
    }

    fn deinit(self: *Connection, allocator: Allocator) void {
        if (self.large_buffer) |buf| {
            allocator.free(buf);
            self.large_buffer = null;
        }
    }
};

pub const EpollWorker = struct {
    allocator: Allocator,
    worker_id: usize,
    cpu_id: u32,
    epoll_fd: i32,
    // TODO(perf): AutoHashMap allocates on insert/growth. Consider a pre-sized
    // flat array indexed by fd (bounded by max_connections) for zero-alloc lookup.
    connections: std.AutoHashMap(std.posix.fd_t, *Connection),
    handler_registry_ptr: *anyopaque,
    handler_dispatch_fn: *const fn (*anyopaque, fd: std.posix.fd_t, msg_type: u8, data: []const u8, response_buf: []u8) ?[]const u8,
    shutdown: *std.atomic.Value(bool),
    requests_processed: std.atomic.Value(u64),
    active_connections: ?*std.atomic.Value(usize),

    const MAX_EVENTS = 256; // Optimal batch size for cache efficiency
    const CONNECTION_TIMEOUT_MS = 30_000;
    const CLEANUP_INTERVAL_MS = 1_000; // Time-based cleanup every 1s
    const MAX_MESSAGE_SIZE: u32 = 16 * 1024 * 1024;

    pub fn init(
        allocator: Allocator,
        worker_id: usize,
        cpu_id: u32,
        handler_registry_ptr: *anyopaque,
        handler_dispatch_fn: *const fn (*anyopaque, fd: std.posix.fd_t, msg_type: u8, data: []const u8, response_buf: []u8) ?[]const u8,
        shutdown: *std.atomic.Value(bool),
        active_connections: ?*std.atomic.Value(usize),
    ) !EpollWorker {
        const epoll_fd = try std.posix.epoll_create1(linux.EPOLL.CLOEXEC);

        return EpollWorker{
            .allocator = allocator,
            .worker_id = worker_id,
            .cpu_id = cpu_id,
            .epoll_fd = epoll_fd,
            .connections = std.AutoHashMap(std.posix.fd_t, *Connection).init(allocator),
            .handler_registry_ptr = handler_registry_ptr,
            .handler_dispatch_fn = handler_dispatch_fn,
            .shutdown = shutdown,
            .requests_processed = std.atomic.Value(u64).init(0),
            .active_connections = active_connections,
        };
    }

    pub fn deinit(self: *EpollWorker) void {
        // Clean up all connections
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            const conn = entry.value_ptr.*;
            conn.deinit(self.allocator);
            std.posix.close(conn.fd);
            self.allocator.destroy(conn);
        }
        self.connections.deinit();
        std.posix.close(self.epoll_fd);
    }

    pub fn addConnection(self: *EpollWorker, fd: std.posix.fd_t) !void {
        const conn = try self.allocator.create(Connection);
        conn.* = Connection.init(fd);

        try self.connections.put(fd, conn);

        // Add to epoll with edge-triggered mode
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.RDHUP,
            .data = .{ .fd = fd },
        };

        try std.posix.epoll_ctl(
            self.epoll_fd,
            linux.EPOLL.CTL_ADD,
            fd,
            &event,
        );
    }

    pub fn run(self: *EpollWorker) void {
        // Pin to CPU
        const numa = @import("numa.zig");
        numa.pinThreadToCpu(self.cpu_id) catch |err| {
            std.log.err("Worker {} failed to pin to CPU {}: {}", .{ self.worker_id, self.cpu_id, err });
        };

        std.log.debug("Event-driven worker {} started on CPU {}", .{ self.worker_id, self.cpu_id });

        var events: [MAX_EVENTS]linux.epoll_event = undefined;
        var last_batch_full = false;
        var last_cleanup_time = std.time.milliTimestamp();

        while (!self.shutdown.load(.acquire)) {
            // Adaptive polling: use 0 timeout if last batch was full (more events likely ready)
            // This drains all ready events without syscall overhead
            const timeout: i32 = if (last_batch_full) 0 else 1000;
            const nfds = std.posix.epoll_wait(self.epoll_fd, &events, timeout);

            last_batch_full = (@as(usize, @intCast(nfds)) == MAX_EVENTS);

            // Process ready connections
            for (events[0..@intCast(nfds)]) |event| {
                const fd = event.data.fd;

                if (self.connections.get(fd)) |conn| {
                    self.handleConnection(conn) catch |err| {
                        std.log.debug("Connection {} error: {}", .{ fd, err });
                        self.closeConnection(fd);
                    };
                }
            }

            // Time-based stale connection cleanup (every CLEANUP_INTERVAL_MS)
            const now = std.time.milliTimestamp();
            if (now - last_cleanup_time >= CLEANUP_INTERVAL_MS) {
                self.cleanupStaleConnections();
                last_cleanup_time = now;
            }
        }

        std.log.info("Worker {} shutting down ({} requests processed)", .{
            self.worker_id,
            self.requests_processed.load(.monotonic),
        });
    }

    fn handleConnection(self: *EpollWorker, conn: *Connection) !void {
        conn.last_activity = std.time.milliTimestamp();

        while (true) {
            switch (conn.state) {
                .reading_header => {
                    const n = std.posix.read(conn.fd, conn.header[conn.header_pos..5]) catch |err| {
                        if (err == error.WouldBlock) return; // No more data available
                        return err;
                    };

                    if (n == 0) return error.ConnectionClosed;

                    conn.header_pos += n;
                    if (conn.header_pos >= 5) {
                        conn.msg_type = conn.header[0];
                        conn.message_length = std.mem.readInt(u32, conn.header[1..5], .big);

                        if (conn.message_length > MAX_MESSAGE_SIZE) {
                            return error.MessageTooLarge;
                        }

                        conn.state = .reading_body;
                        conn.body_pos = 0;
                    } else {
                        return; // Need more data
                    }
                },

                .reading_body => {
                    // TODO(perf): Large message allocation on hot path. Consider a
                    // per-connection pre-allocated large buffer or a pool to avoid
                    // heap allocation for every oversized message.
                    const target_buf = if (conn.message_length > conn.read_buffer.len) blk: {
                        if (conn.large_buffer == null) {
                            conn.large_buffer = try self.allocator.alloc(u8, conn.message_length);
                        }
                        break :blk conn.large_buffer.?;
                    } else conn.read_buffer[0..conn.message_length];

                    const n = std.posix.read(conn.fd, target_buf[conn.body_pos..]) catch |err| {
                        if (err == error.WouldBlock) return;
                        return err;
                    };

                    if (n == 0) return error.ConnectionClosed;

                    conn.body_pos += n;
                    if (conn.body_pos >= conn.message_length) {
                        conn.state = .processing;
                    } else {
                        return; // Need more data
                    }
                },

                .processing => {
                    // Process the message
                    const request_data = if (conn.large_buffer) |buf|
                        buf[0..conn.message_length]
                    else
                        conn.read_buffer[0..conn.message_length];

                    const response = self.handler_dispatch_fn(
                        self.handler_registry_ptr,
                        conn.fd,
                        conn.msg_type,
                        request_data,
                        &conn.write_buffer,
                    ) orelse {
                        return error.HandlerFailed;
                    };

                    // Prepare response header (in-place before write_buffer)
                    var header: [5]u8 = undefined;
                    header[0] = conn.msg_type;
                    std.mem.writeInt(u32, header[1..5], @as(u32, @intCast(response.len)), .big);

                    // Use writev for scatter-gather write: header + payload in ONE syscall.
                    // Eliminates 2 setsockopt(TCP_CORK) calls per request (~1-2µs saved).
                    var iov = [2]std.posix.iovec_const{
                        .{ .base = &header, .len = 5 },
                        .{ .base = response.ptr, .len = response.len },
                    };

                    const total_write_len = 5 + response.len;
                    var total_written: usize = 0;

                    while (total_written < total_write_len) {
                        const rc = std.os.linux.writev(conn.fd, &iov, 2);
                        const n = switch (std.posix.errno(rc)) {
                            .SUCCESS => rc,
                            .AGAIN => {
                                // Socket buffer full — brief spin, then retry.
                                // TODO: For production, register EPOLLOUT and yield.
                                std.atomic.spinLoopHint();
                                continue;
                            },
                            else => return error.WriteFailed,
                        };

                        if (n == 0) return error.ConnectionClosed;
                        total_written += n;

                        // Advance iov past already-written bytes
                        var remaining = n;
                        for (&iov) |*v| {
                            if (remaining >= v.len) {
                                remaining -= v.len;
                                v.base += v.len;
                                v.len = 0;
                            } else {
                                v.base += remaining;
                                v.len -= remaining;
                                break;
                            }
                        }
                    }

                    _ = self.requests_processed.fetchAdd(1, .monotonic);

                    // Reset for next message
                    conn.state = .reading_header;
                    conn.header_pos = 0;
                    conn.body_pos = 0;
                    if (conn.large_buffer) |buf| {
                        self.allocator.free(buf);
                        conn.large_buffer = null;
                    }

                    // Continue processing if more data available
                    continue;
                },

                .writing_response, .closing => unreachable,
            }
        }
    }

    fn closeConnection(self: *EpollWorker, fd: std.posix.fd_t) void {
        if (self.connections.fetchRemove(fd)) |entry| {
            const conn = entry.value;
            conn.deinit(self.allocator);
            self.allocator.destroy(conn);
            std.posix.close(fd);

            // Decrement global connection counter
            if (self.active_connections) |counter| {
                _ = counter.fetchSub(1, .monotonic);
            }
        }
    }

    fn cleanupStaleConnections(self: *EpollWorker) void {
        const now = std.time.milliTimestamp();

        // Stack buffer for fds to close (max 100 at a time)
        var to_close: [100]i32 = undefined;
        var to_close_count: usize = 0;

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            const conn = entry.value_ptr.*;
            if (now - conn.last_activity > CONNECTION_TIMEOUT_MS) {
                if (to_close_count < to_close.len) {
                    to_close[to_close_count] = entry.key_ptr.*;
                    to_close_count += 1;
                }
            }
        }

        for (to_close[0..to_close_count]) |fd| {
            std.log.debug("Closing stale connection {}", .{fd});
            self.closeConnection(fd);
        }
    }
};
