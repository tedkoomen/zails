/// UDP Listener - Socket binding, multicast join, recv loop
///
/// Parameterized by a comptime protocol tuple for zero-overhead dispatch.
/// Each listener binds one UDP socket and dispatches to one protocol parser.
///
/// Data flow:
///   recvfrom → dispatchParse (inline for) → BinaryProtocol.parse → toJSON → Event → MessageBus
///
/// String ownership: init() dupes all string fields from FeedConfig.
/// deinit() frees them. Callers do not need to keep FeedConfig alive.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Event = @import("../event.zig").Event;
const generateEventId = @import("../event.zig").generateEventId;
const MessageBus = @import("../message_bus/message_bus.zig").MessageBus;
const FeedConfig = @import("feed_config.zig").FeedConfig;
const SequenceTracker = @import("sequence_tracker.zig").SequenceTracker;

/// Create a UDP listener parameterized by comptime protocol definitions.
/// Protocols is a tuple of structs, each with:
///   .PROTOCOL_ID: u8
///   .Parser: BinaryProtocol(...) type (has parse, toJSON, MIN_MESSAGE_SIZE)
///   .TOPIC: []const u8
pub fn UdpListener(comptime Protocols: anytype) type {
    // Comptime validation: ensure all PROTOCOL_IDs are unique
    comptime {
        const proto_info = @typeInfo(@TypeOf(Protocols)).@"struct";
        for (proto_info.fields, 0..) |f, i| {
            const p = @field(Protocols, f.name);
            for (proto_info.fields[i + 1 ..]) |g| {
                const q = @field(Protocols, g.name);
                if (p.PROTOCOL_ID == q.PROTOCOL_ID) {
                    @compileError(std.fmt.comptimePrint(
                        "Duplicate PROTOCOL_ID {d} in protocol tuple",
                        .{p.PROTOCOL_ID},
                    ));
                }
            }
        }
    }

    return struct {
        const Self = @This();

        fd: std.posix.fd_t,
        protocol_id: u8,
        publish_topic: []const u8, // Owned (duped from config)
        feed_name: []const u8, // Owned (duped from config)
        bus: *MessageBus,
        shutdown: *std.atomic.Value(bool),
        seq_tracker: SequenceTracker,
        allocator: Allocator,

        // Atomic stats (lock-free)
        datagrams_received: std.atomic.Value(u64),
        parse_errors: std.atomic.Value(u64),
        bytes_received: std.atomic.Value(u64),
        events_published: std.atomic.Value(u64),

        // Max UDP datagram, stack-allocated in recv loop
        recv_buffer: [65536]u8,

        pub fn init(
            config: FeedConfig,
            bus: *MessageBus,
            shutdown: *std.atomic.Value(bool),
            allocator: Allocator,
        ) !Self {
            // Dupe strings so listener owns its data and doesn't depend
            // on FeedConfig lifetime
            const topic_copy = try allocator.dupe(u8, config.publish_topic);
            errdefer allocator.free(topic_copy);
            const name_copy = try allocator.dupe(u8, config.name);
            errdefer allocator.free(name_copy);

            // Create UDP socket (non-blocking)
            const fd = try std.posix.socket(
                std.posix.AF.INET,
                std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK,
                0,
            );
            errdefer std.posix.close(fd);

            // SO_REUSEADDR
            const reuseaddr: c_int = 1;
            try std.posix.setsockopt(
                fd,
                std.posix.SOL.SOCKET,
                std.posix.SO.REUSEADDR,
                &std.mem.toBytes(reuseaddr),
            );

            // SO_REUSEPORT (non-fatal if unsupported)
            const reuseport: c_int = 1;
            std.posix.setsockopt(
                fd,
                std.posix.SOL.SOCKET,
                std.posix.SO.REUSEPORT,
                &std.mem.toBytes(reuseport),
            ) catch |err| {
                std.log.warn("[{s}] Failed to set SO_REUSEPORT: {}", .{ config.name, err });
            };

            // SO_RCVBUF (non-fatal if kernel limits prevent requested size)
            const rcvbuf: c_int = @intCast(@min(config.recv_buffer_size, std.math.maxInt(c_int)));
            std.posix.setsockopt(
                fd,
                std.posix.SOL.SOCKET,
                std.posix.SO.RCVBUF,
                &std.mem.toBytes(rcvbuf),
            ) catch |err| {
                std.log.warn("[{s}] Failed to set SO_RCVBUF to {}: {}", .{ config.name, config.recv_buffer_size, err });
            };

            // Bind
            const address = try std.net.Address.parseIp4(config.bind_address, config.bind_port);
            try std.posix.bind(fd, &address.any, address.getOsSockLen());

            // Join multicast group if configured
            if (config.multicast_group) |group| {
                try joinMulticast(fd, group, config.multicast_interface, config.name);
            }

            std.log.info("[{s}] UDP listener bound to {s}:{d} (protocol_id={d})", .{
                config.name,
                config.bind_address,
                config.bind_port,
                config.protocol_id,
            });

            return Self{
                .fd = fd,
                .protocol_id = config.protocol_id,
                .publish_topic = topic_copy,
                .feed_name = name_copy,
                .bus = bus,
                .shutdown = shutdown,
                .seq_tracker = SequenceTracker.init(config.initial_sequence),
                .allocator = allocator,
                .datagrams_received = std.atomic.Value(u64).init(0),
                .parse_errors = std.atomic.Value(u64).init(0),
                .bytes_received = std.atomic.Value(u64).init(0),
                .events_published = std.atomic.Value(u64).init(0),
                .recv_buffer = undefined,
            };
        }

        /// Main recv loop — runs on its own thread until shutdown
        pub fn run(self: *Self) void {
            std.log.info("[{s}] Feed listener started", .{self.feed_name});

            while (!self.shutdown.load(.acquire)) {
                const recv_result = std.posix.recvfrom(
                    self.fd,
                    &self.recv_buffer,
                    0,
                    null,
                    null,
                );

                if (recv_result) |bytes_read| {
                    if (bytes_read == 0) continue;

                    _ = self.datagrams_received.fetchAdd(1, .monotonic);
                    _ = self.bytes_received.fetchAdd(bytes_read, .monotonic);

                    self.dispatchParse(self.recv_buffer[0..bytes_read]);
                } else |err| {
                    if (err == error.WouldBlock) {
                        // No data available — brief sleep to avoid busy-spinning
                        std.Thread.sleep(100_000); // 100us
                        continue;
                    }
                    std.log.warn("[{s}] recvfrom error: {}", .{ self.feed_name, err });
                }
            }

            std.log.info("[{s}] Feed listener stopped", .{self.feed_name});
        }

        /// Comptime dispatch: protocol_id -> parser (inline for)
        fn dispatchParse(self: *Self, datagram: []const u8) void {
            inline for (Protocols) |P| {
                if (self.protocol_id == P.PROTOCOL_ID) {
                    const result = P.Parser.parse(datagram);
                    if (result.isOk()) {
                        self.publishEvent(P, &result.msg);
                    } else {
                        _ = self.parse_errors.fetchAdd(1, .monotonic);
                    }
                    return;
                }
            }
            // No matching protocol — config error
            _ = self.parse_errors.fetchAdd(1, .monotonic);
        }

        /// Serialize parsed message to JSON and publish to message bus.
        /// Only allocates the data payload (topic and model_type are borrowed).
        fn publishEvent(self: *Self, comptime P: anytype, msg: *const P.Parser.Message) void {
            // Serialize to JSON in stack buffer
            var json_buf: [8192]u8 = undefined;
            const json = P.Parser.toJSON(msg, &json_buf) catch |err| {
                _ = self.parse_errors.fetchAdd(1, .monotonic);
                std.log.debug("[{s}] toJSON failed: {}", .{ self.feed_name, err });
                return;
            };

            // Create a fully-owned event so the bus can free it on drop or after delivery.
            // Previous approach only duped data with owned=false, leaking data_copy on
            // successful publish (deinit was a no-op since owned=false).
            const event = Event.initOwned(
                self.allocator,
                .custom,
                self.publish_topic,
                P.Parser.protocol_name,
                0,
                json,
            ) catch {
                _ = self.parse_errors.fetchAdd(1, .monotonic);
                return;
            };

            if (!self.bus.publish(event)) {
                // Queue full — publish() already calls event.deinit() for owned events
            } else {
                _ = self.events_published.fetchAdd(1, .monotonic);
            }
        }

        /// Get the sequence tracker for external use (e.g., checking
        /// sequence numbers extracted from parsed messages)
        pub fn getSequenceTracker(self: *Self) *SequenceTracker {
            return &self.seq_tracker;
        }

        pub fn getStats(self: *const Self) Stats {
            return .{
                .datagrams_received = self.datagrams_received.load(.acquire),
                .parse_errors = self.parse_errors.load(.acquire),
                .bytes_received = self.bytes_received.load(.acquire),
                .events_published = self.events_published.load(.acquire),
                .seq_stats = self.seq_tracker.getStats(),
            };
        }

        pub const Stats = struct {
            datagrams_received: u64,
            parse_errors: u64,
            bytes_received: u64,
            events_published: u64,
            seq_stats: SequenceTracker.Stats,
        };

        pub fn deinit(self: *Self) void {
            std.posix.close(self.fd);
            self.allocator.free(self.publish_topic);
            self.allocator.free(self.feed_name);
        }
    };
}

/// Join a multicast group via IP_ADD_MEMBERSHIP
fn joinMulticast(
    fd: std.posix.fd_t,
    group: []const u8,
    iface: ?[]const u8,
    feed_name: []const u8,
) !void {
    // Parse multicast group address
    const group_addr = try std.net.Address.parseIp4(group, 0);

    // Build ip_mreq struct (two consecutive in_addr fields)
    var mreq: extern struct {
        imr_multiaddr: u32,
        imr_interface: u32,
    } = .{
        .imr_multiaddr = group_addr.in.sa.addr,
        .imr_interface = 0, // INADDR_ANY
    };

    if (iface) |iface_addr| {
        const iface_parsed = try std.net.Address.parseIp4(iface_addr, 0);
        mreq.imr_interface = iface_parsed.in.sa.addr;
    }

    // IP_ADD_MEMBERSHIP = 35 on Linux
    const IP_ADD_MEMBERSHIP: u32 = 35;
    try std.posix.setsockopt(
        fd,
        std.posix.IPPROTO.IP,
        IP_ADD_MEMBERSHIP,
        std.mem.asBytes(&mreq),
    );

    std.log.info("[{s}] Joined multicast group {s}", .{ feed_name, group });
}

// ====================
// Tests
// ====================

test "UdpListener compiles with protocol tuple" {
    const binary_protocol = @import("binary_protocol.zig");
    const TestProto = binary_protocol.BinaryProtocol("Test", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
        .value = .{ .type = .u32, .offset = 1 },
    });

    const TestProtocols = .{
        .{ .PROTOCOL_ID = @as(u8, 1), .Parser = TestProto, .TOPIC = "Feed.test" },
    };

    const Listener = UdpListener(TestProtocols);

    // Verify the type compiles and has expected declarations
    try std.testing.expect(@hasDecl(Listener, "init"));
    try std.testing.expect(@hasDecl(Listener, "run"));
    try std.testing.expect(@hasDecl(Listener, "deinit"));
    try std.testing.expect(@hasDecl(Listener, "getStats"));
    try std.testing.expect(@hasDecl(Listener, "getSequenceTracker"));
}

test "UdpListener multiple protocols compile" {
    const binary_protocol = @import("binary_protocol.zig");
    const Proto1 = binary_protocol.BinaryProtocol("Proto1", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
    });
    const Proto2 = binary_protocol.BinaryProtocol("Proto2", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
        .value = .{ .type = .u32, .offset = 1 },
    });

    const MultiProtocols = .{
        .{ .PROTOCOL_ID = @as(u8, 1), .Parser = Proto1, .TOPIC = "Feed.p1" },
        .{ .PROTOCOL_ID = @as(u8, 2), .Parser = Proto2, .TOPIC = "Feed.p2" },
    };

    const Listener = UdpListener(MultiProtocols);
    try std.testing.expect(@hasDecl(Listener, "init"));
}

test "IPv4 address parsing" {
    const addr = try std.net.Address.parseIp4("0.0.0.0", 5000);
    try std.testing.expectEqual(@as(u16, 5000), std.mem.bigToNative(u16, addr.in.sa.port));
}

test "localhost address parsing" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 8080);
    try std.testing.expectEqual(@as(u16, 8080), std.mem.bigToNative(u16, addr.in.sa.port));
}

test "UdpListener localhost send and receive" {
    const binary_protocol = @import("binary_protocol.zig");
    const TestProto = binary_protocol.BinaryProtocol("Test", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
        .value = .{ .type = .u32, .offset = 1 },
    });

    const TestProtocols = .{
        .{ .PROTOCOL_ID = @as(u8, 1), .Parser = TestProto, .TOPIC = "Feed.test" },
    };

    const allocator = std.testing.allocator;

    // Create a minimal message bus (not started — publish will drop to queue)
    var bus = try MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1,
        .flush_interval_ms = 100,
    });
    defer bus.deinit();

    var shutdown = std.atomic.Value(bool).init(false);

    const feed_config = FeedConfig{
        .name = "test_feed",
        .bind_address = "127.0.0.1",
        .bind_port = 0, // OS-assigned port
        .multicast_group = null,
        .multicast_interface = null,
        .protocol_id = 1,
        .enabled = true,
        .recv_buffer_size = 65536,
        .publish_topic = "Feed.test",
        .initial_sequence = 0,
    };

    const Listener = UdpListener(TestProtocols);
    var listener = try Listener.init(feed_config, &bus, &shutdown, allocator);
    defer listener.deinit();

    // Get the OS-assigned port
    var addr_buf: std.posix.sockaddr.storage = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try std.posix.getsockname(listener.fd, @ptrCast(&addr_buf), &addr_len);
    const bound_addr: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&addr_buf));
    const port = std.mem.bigToNative(u16, bound_addr.port);

    // Spawn listener thread
    const listener_thread = try std.Thread.spawn(.{}, Listener.run, .{&listener});

    // Create a sender socket
    const sender_fd = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM,
        0,
    );
    defer std.posix.close(sender_fd);

    const dest = try std.net.Address.parseIp4("127.0.0.1", port);

    // Craft a valid datagram: msg_type=0x42, value=0x00000064 (100 in big-endian)
    var datagram: [5]u8 = undefined;
    datagram[0] = 0x42; // msg_type
    std.mem.writeInt(u32, datagram[1..5], 100, .big); // value

    // Send 3 datagrams
    for (0..3) |_| {
        _ = try std.posix.sendto(
            sender_fd,
            &datagram,
            0,
            &dest.any,
            dest.getOsSockLen(),
        );
    }

    // Give listener time to process
    std.Thread.sleep(50_000_000); // 50ms

    // Signal shutdown and join
    shutdown.store(true, .release);
    listener_thread.join();

    // Verify stats
    const stats = listener.getStats();
    try std.testing.expectEqual(@as(u64, 3), stats.datagrams_received);
    try std.testing.expectEqual(@as(u64, 0), stats.parse_errors);
    try std.testing.expectEqual(@as(u64, 15), stats.bytes_received); // 3 * 5 bytes
}

test "UdpListener parse error for short datagram" {
    const binary_protocol = @import("binary_protocol.zig");
    const TestProto = binary_protocol.BinaryProtocol("Test", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
        .value = .{ .type = .u32, .offset = 1 },
    });

    const TestProtocols = .{
        .{ .PROTOCOL_ID = @as(u8, 1), .Parser = TestProto, .TOPIC = "Feed.test" },
    };

    const allocator = std.testing.allocator;

    var bus = try MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1,
        .flush_interval_ms = 100,
    });
    defer bus.deinit();

    var shutdown = std.atomic.Value(bool).init(false);

    const feed_config = FeedConfig{
        .name = "test_feed_short",
        .bind_address = "127.0.0.1",
        .bind_port = 0,
        .multicast_group = null,
        .multicast_interface = null,
        .protocol_id = 1,
        .enabled = true,
        .recv_buffer_size = 65536,
        .publish_topic = "Feed.test",
        .initial_sequence = 0,
    };

    const Listener = UdpListener(TestProtocols);
    var listener = try Listener.init(feed_config, &bus, &shutdown, allocator);
    defer listener.deinit();

    // Get OS-assigned port
    var addr_buf: std.posix.sockaddr.storage = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try std.posix.getsockname(listener.fd, @ptrCast(&addr_buf), &addr_len);
    const bound_addr: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&addr_buf));
    const port = std.mem.bigToNative(u16, bound_addr.port);

    const listener_thread = try std.Thread.spawn(.{}, Listener.run, .{&listener});

    const sender_fd = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM,
        0,
    );
    defer std.posix.close(sender_fd);

    const dest = try std.net.Address.parseIp4("127.0.0.1", port);

    // Send a datagram that's too short (2 bytes, but protocol needs 5)
    const short_datagram = [_]u8{ 0x42, 0x01 };
    _ = try std.posix.sendto(
        sender_fd,
        &short_datagram,
        0,
        &dest.any,
        dest.getOsSockLen(),
    );

    // Also send one valid datagram
    var valid_datagram: [5]u8 = undefined;
    valid_datagram[0] = 0x42;
    std.mem.writeInt(u32, valid_datagram[1..5], 200, .big);
    _ = try std.posix.sendto(
        sender_fd,
        &valid_datagram,
        0,
        &dest.any,
        dest.getOsSockLen(),
    );

    std.Thread.sleep(50_000_000); // 50ms

    shutdown.store(true, .release);
    listener_thread.join();

    const stats = listener.getStats();
    try std.testing.expectEqual(@as(u64, 2), stats.datagrams_received);
    try std.testing.expectEqual(@as(u64, 1), stats.parse_errors); // short datagram
    try std.testing.expectEqual(@as(u64, 7), stats.bytes_received); // 2 + 5
}

test "UdpListener unmatched protocol_id counts parse error" {
    const binary_protocol = @import("binary_protocol.zig");
    const TestProto = binary_protocol.BinaryProtocol("Test", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
    });

    const TestProtocols = .{
        .{ .PROTOCOL_ID = @as(u8, 1), .Parser = TestProto, .TOPIC = "Feed.test" },
    };

    const allocator = std.testing.allocator;

    var bus = try MessageBus.init(allocator, .{
        .queue_capacity = 64,
        .worker_count = 1,
        .flush_interval_ms = 100,
    });
    defer bus.deinit();

    var shutdown = std.atomic.Value(bool).init(false);

    // Use protocol_id 99 — no matching protocol in the tuple
    const feed_config = FeedConfig{
        .name = "test_unmatched",
        .bind_address = "127.0.0.1",
        .bind_port = 0,
        .multicast_group = null,
        .multicast_interface = null,
        .protocol_id = 99,
        .enabled = true,
        .recv_buffer_size = 65536,
        .publish_topic = "Feed.test",
        .initial_sequence = 0,
    };

    const Listener = UdpListener(TestProtocols);
    var listener = try Listener.init(feed_config, &bus, &shutdown, allocator);
    defer listener.deinit();

    // Get OS-assigned port
    var addr_buf: std.posix.sockaddr.storage = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try std.posix.getsockname(listener.fd, @ptrCast(&addr_buf), &addr_len);
    const bound_addr: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&addr_buf));
    const port = std.mem.bigToNative(u16, bound_addr.port);

    const listener_thread = try std.Thread.spawn(.{}, Listener.run, .{&listener});

    const sender_fd = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM,
        0,
    );
    defer std.posix.close(sender_fd);

    const dest = try std.net.Address.parseIp4("127.0.0.1", port);

    // Send a valid-sized datagram — but protocol_id won't match any protocol
    const datagram = [_]u8{0x01};
    _ = try std.posix.sendto(
        sender_fd,
        &datagram,
        0,
        &dest.any,
        dest.getOsSockLen(),
    );

    std.Thread.sleep(50_000_000); // 50ms

    shutdown.store(true, .release);
    listener_thread.join();

    const stats = listener.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.datagrams_received);
    try std.testing.expectEqual(@as(u64, 1), stats.parse_errors); // no matching protocol
    try std.testing.expectEqual(@as(u64, 0), stats.events_published);
}
