/// Main entry point - Convention-based server framework
/// Handlers are auto-discovered from handlers/ folder at compile time
/// NO virtual inheritance, NO function pointers - pure comptime dispatch

const std = @import("std");
const Config = @import("config.zig").Config;
const SignalHandler = @import("signals.zig").SignalHandler;
const numa = @import("numa.zig");
const epoll_threadpool = @import("epoll_threadpool.zig");
const handler_registry = @import("handler_registry.zig");
const config_system = @import("config_system.zig");
const metrics_mod = @import("metrics.zig");
const clickhouse_client = @import("clickhouse_client.zig");
const async_clickhouse = @import("async_clickhouse.zig");
const message_bus = @import("message_bus/mod.zig");
const udp = @import("udp/mod.zig");
const net = std.net;

// Export globals module for handlers
pub const globals = @import("globals.zig");

// Import all handlers from handlers/ folder
const handlers = @import("handlers");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse configuration
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = Config.parseArgs(allocator, args) catch |err| {
        if (err == error.HelpRequested) {
            return;
        }
        std.log.err("Failed to parse arguments: {}", .{err});
        return err;
    };
    defer config.deinit(allocator);

    try config.validate();

    if (config.verbose) {
        std.log.info("=== High-Performance Server Framework ===", .{});
        std.log.info("Features:", .{});
        std.log.info("  ✓ Convention-based handlers (handlers/ folder)", .{});
        std.log.info("  ✓ Comptime dispatch (NO virtual inheritance)", .{});
        std.log.info("  ✓ Lock-free object pools", .{});
        std.log.info("  ✓ Epoll-based event-driven workers", .{});
        std.log.info("  ✓ NUMA-aware worker placement", .{});
        std.log.info("", .{});
    }

    // ========================================
    // Initialize Message Bus (Event-Driven Architecture)
    // ========================================
    std.log.info("Initializing message bus...", .{});
    var bus_instance = try message_bus.MessageBus.init(allocator, .{
        .queue_capacity = 8192,
        .worker_count = 4,
        .flush_interval_ms = 50,
    });
    defer bus_instance.deinit();

    try bus_instance.start();
    globals.global_message_bus = &bus_instance;
    globals.ctx.message_bus = &bus_instance;

    std.log.info("✓ Message bus started (4 workers, 8192 queue capacity)", .{});
    std.log.info("", .{});

    // Create handler registry (comptime dispatch from handlers/ folder)
    const Registry = handler_registry.HandlerRegistry(handlers.handler_modules);
    var registry = try Registry.init(allocator);
    defer registry.deinit();

    // Post-initialize handlers (configure with message bus, etc.)
    try registry.postInit(allocator);

    // Initialize runtime controller for metrics and profiling
    // Create default config for runtime controller
    var default_config = try config_system.ZailsConfig.default(allocator);
    defer default_config.deinit(allocator);

    // ========================================
    // Initialize UDP Feed Manager (Exchange Connectivity)
    // ========================================

    // Define protocol registry (comptime tuple — same pattern as handler_modules)
    const example_itch = @import("protocols/example_itch.zig");
    const FeedProtocols = .{
        .{ .PROTOCOL_ID = example_itch.PROTOCOL_ID, .Parser = example_itch.AddOrder, .TOPIC = example_itch.TOPIC },
    };
    const FM = udp.FeedManager(FeedProtocols);

    // Initialize feed manager if feeds are configured
    var feed_manager: ?FM = null;
    if (default_config.feeds.enabled and default_config.feeds.feeds.len > 0) {
        // Convert config entries to FeedConfig slice
        const feed_configs = try allocator.alloc(udp.FeedConfig, default_config.feeds.feeds.len);
        defer allocator.free(feed_configs);

        for (default_config.feeds.feeds, 0..) |entry, i| {
            feed_configs[i] = .{
                .name = entry.name,
                .bind_address = entry.bind_address,
                .bind_port = entry.bind_port,
                .multicast_group = entry.multicast_group,
                .multicast_interface = entry.multicast_interface,
                .protocol_id = entry.protocol_id,
                .enabled = entry.enabled,
                .recv_buffer_size = entry.recv_buffer_size,
                .publish_topic = entry.publish_topic,
                .initial_sequence = entry.initial_sequence,
            };
        }

        feed_manager = try FM.init(allocator, feed_configs, &bus_instance);
        try feed_manager.?.start();
        globals.global_feed_manager = &feed_manager.?;
        globals.ctx.feed_manager = &feed_manager.?;
        std.log.info("✓ Feed manager started ({} feed(s))", .{feed_configs.len});
    } else {
        std.log.info("Feed manager disabled (no feeds configured)", .{});
    }
    std.log.info("", .{});

    defer {
        if (feed_manager) |*fm| {
            fm.deinit();
        }
    }

    var runtime_controller = config_system.RuntimeController.init(&default_config);
    globals.global_runtime_controller = &runtime_controller;
    globals.ctx.runtime_controller = &runtime_controller;

    // Initialize metrics registry
    var metrics_registry = metrics_mod.MetricsRegistry.init();
    globals.global_metrics = &metrics_registry;
    globals.ctx.metrics = &metrics_registry;

    // Initialize ClickHouse writer if enabled
    var clickhouse_writer: ?*async_clickhouse.AsyncClickHouseWriter = null;
    var clickhouse_http_client: ?*clickhouse_client.ClickHouseClient = null;
    if (default_config.persistence.clickhouse.enabled) {
        std.log.info("Initializing ClickHouse writer...", .{});

        // Parse URL to extract host and port
        const url_str = default_config.persistence.clickhouse.url;
        const uri = std.Uri.parse(url_str) catch {
            std.log.err("Failed to parse ClickHouse URL: {s}", .{url_str});
            return error.InvalidClickHouseUrl;
        };

        // Extract host from URI component
        const host = if (uri.host) |h| switch (h) {
            .raw => |s| s,
            .percent_encoded => |s| s,
        } else "localhost";
        const port = uri.port orelse 8123;

        const ch_config = clickhouse_client.ClickHouseConfig{
            .host = host,
            .port = port,
            .database = default_config.persistence.clickhouse.database,
            .username = default_config.persistence.clickhouse.username,
            .password = default_config.persistence.clickhouse.password,
            .pool_size = default_config.persistence.clickhouse.pool_size,
        };

        clickhouse_http_client = try allocator.create(clickhouse_client.ClickHouseClient);
        clickhouse_http_client.?.* = try clickhouse_client.ClickHouseClient.init(allocator, ch_config);

        const writer_config = async_clickhouse.AsyncWriterConfig{
            .batch_size = default_config.persistence.clickhouse.batch_size,
            .flush_interval_seconds = default_config.persistence.clickhouse.flush_interval_seconds,
            .buffer_capacity = default_config.persistence.clickhouse.buffer_capacity,
            .table_name = default_config.persistence.clickhouse.table_name,
        };

        clickhouse_writer = try async_clickhouse.AsyncClickHouseWriter.init(
            allocator,
            clickhouse_http_client.?,
            writer_config,
        );

        // Initialize global - the writer's background thread ensures visibility
        globals.global_clickhouse = clickhouse_writer;
        globals.ctx.clickhouse = clickhouse_writer;
        std.log.info("ClickHouse writer initialized (host={s}, port={d}, database={s})", .{
            host,
            port,
            default_config.persistence.clickhouse.database,
        });
    }

    defer {
        if (clickhouse_writer) |writer| {
            writer.deinit();
        }
        if (clickhouse_http_client) |client| {
            client.deinit();
            allocator.destroy(client);
        }
    }

    std.log.info("Configuration:", .{});
    std.log.info("  Ports: {d} port(s) configured", .{config.ports.len});
    if (config.worker_threads) |wt| {
        std.log.info("  Workers: {d}", .{wt});
    } else {
        std.log.info("  Workers: auto", .{});
    }
    std.log.info("  NUMA enabled: {}", .{config.enable_numa});
    std.log.info("  Handlers: {d}", .{Registry.getHandlerCount()});
    std.log.info("", .{});

    // Detect NUMA topology
    var topology = try numa.NumaTopology.detect(allocator);
    defer topology.deinit();

    const total_workers = config.worker_threads orelse (topology.total_cpus * 2);
    const workers_per_node = @max(1, total_workers / topology.nodes.len);

    std.log.info("NUMA topology: {} nodes, {} CPUs, {} workers per node", .{
        topology.nodes.len,
        topology.total_cpus,
        workers_per_node,
    });

    // Connection tracking
    var active_connections = std.atomic.Value(usize).init(0);

    // Create event-driven epoll thread pools (one per NUMA node)
    var thread_pools = try allocator.alloc(
        epoll_threadpool.EpollThreadPool,
        topology.nodes.len,
    );
    defer allocator.free(thread_pools);

    for (topology.nodes, 0..) |node, i| {
        thread_pools[i] = try epoll_threadpool.EpollThreadPool.init(
            allocator,
            node,
            workers_per_node,
            &registry,
            &active_connections,
        );
    }

    defer {
        for (thread_pools) |*pool| {
            pool.deinit();
        }
    }

    // Create listeners with proper socket options
    var listeners = try allocator.alloc(net.Server, config.ports.len);
    defer allocator.free(listeners);

    for (config.ports, 0..) |port, i| {
        const address = try net.Address.parseIp("0.0.0.0", port);
        listeners[i] = try address.listen(.{
            .reuse_address = true,
        });

        // Set TCP socket options for performance
        const sock_fd = listeners[i].stream.handle;

        // SO_REUSEPORT - kernel-level load balancing across workers
        const reuseport: c_int = 1;
        _ = std.posix.setsockopt(
            sock_fd,
            std.posix.SOL.SOCKET,
            15, // SO_REUSEPORT = 15 on Linux
            &std.mem.toBytes(reuseport),
        ) catch |err| {
            std.log.warn("Failed to set SO_REUSEPORT on port {}: {}", .{ port, err });
        };

        // TCP_NODELAY - disable Nagle's algorithm for low latency
        const tcp_nodelay: c_int = 1;
        _ = std.posix.setsockopt(
            sock_fd,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            &std.mem.toBytes(tcp_nodelay),
        ) catch |err| {
            std.log.warn("Failed to set TCP_NODELAY on port {}: {}", .{ port, err });
        };

        // SO_KEEPALIVE - detect dead connections
        const keepalive: c_int = 1;
        _ = std.posix.setsockopt(
            sock_fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.KEEPALIVE,
            &std.mem.toBytes(keepalive),
        ) catch |err| {
            std.log.warn("Failed to set SO_KEEPALIVE on port {}: {}", .{ port, err });
        };

        // Increase receive buffer size
        const rcvbuf: c_int = 256 * 1024; // 256KB
        _ = std.posix.setsockopt(
            sock_fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVBUF,
            &std.mem.toBytes(rcvbuf),
        ) catch |err| {
            std.log.warn("Failed to set SO_RCVBUF on port {}: {}", .{ port, err });
        };

        // Increase send buffer size
        const sndbuf: c_int = 256 * 1024; // 256KB
        _ = std.posix.setsockopt(
            sock_fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDBUF,
            &std.mem.toBytes(sndbuf),
        ) catch |err| {
            std.log.warn("Failed to set SO_SNDBUF on port {}: {}", .{ port, err });
        };

        std.log.info("Listening on port {} with optimized socket options", .{port});
    }

    defer {
        for (listeners) |*listener| {
            listener.deinit();
        }
    }

    var shutdown = std.atomic.Value(bool).init(false);

    // Setup signal handlers for graceful shutdown
    var signal_handler = SignalHandler.init(&shutdown);
    signal_handler.register();

    std.log.info("Server started on {} port(s)", .{config.ports.len});

    if (config.verbose) {
        std.log.info("=== Server Running ===", .{});
        std.log.info("Processing requests with:", .{});
        std.log.info("  • Zero allocations in hot path (arena allocators)", .{});
        std.log.info("  • Optimized syscalls (epoll)", .{});
        std.log.info("  • Zero virtual inheritance (comptime dispatch)", .{});
        std.log.info("Press Ctrl+C to shutdown", .{});
    }

    // Create epoll for efficient multi-listener accept
    const epoll_fd = try std.posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
    defer std.posix.close(epoll_fd);

    // Register all listeners with epoll
    for (listeners, 0..) |*listener, i| {
        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .u64 = i }, // Store listener index
        };
        try std.posix.epoll_ctl(
            epoll_fd,
            std.os.linux.EPOLL.CTL_ADD,
            listener.stream.handle,
            &event,
        );
    }

    // Accept loop with epoll
    var connection_count: usize = 0;
    var rejected_connections: usize = 0;
    var events: [32]std.os.linux.epoll_event = undefined;

    while (!shutdown.load(.acquire)) {
        // Wait for events with timeout to check shutdown flag
        const event_count = std.posix.epoll_wait(epoll_fd, &events, 100);

        for (events[0..event_count]) |event| {
            const listener_idx = event.data.u64;

            // Bounds check to prevent out-of-bounds array access
            if (listener_idx >= listeners.len) {
                std.log.err("Invalid listener index from epoll: {} (max: {})", .{ listener_idx, listeners.len });
                continue;
            }

            var listener = &listeners[listener_idx];

            // Accept all pending connections on this listener
            while (true) {
                // Atomically check and increment connection count to prevent TOCTOU race
                // Use compare-and-swap loop to ensure limit is never exceeded
                var retry_count: usize = 0;
                while (retry_count < 100) : (retry_count += 1) {
                    const current_active = active_connections.load(.monotonic);
                    if (current_active >= config.max_connections) {
                        // Connection limit reached - stop accepting
                        rejected_connections += 1;
                        if (rejected_connections % 1000 == 1) {
                            std.log.warn("Connection limit reached ({}/{}), rejecting new connections ({} total rejected)", .{ current_active, config.max_connections, rejected_connections });
                        }
                        break;
                    }

                    // Try to reserve a connection slot atomically
                    if (active_connections.cmpxchgWeak(
                        current_active,
                        current_active + 1,
                        .monotonic,
                        .monotonic,
                    )) |_| {
                        // CAS failed, retry
                        continue;
                    }

                    // Successfully reserved a slot, now accept the connection
                    const connection = listener.accept() catch |err| {
                        // Accept failed, release the reservation
                        _ = active_connections.fetchSub(1, .monotonic);

                        if (err == error.WouldBlock) break; // No more pending
                        std.log.debug("Accept error on port {}: {}", .{ config.ports[listener_idx], err });
                        break;
                    };

                    // Set TCP_NODELAY on accepted connection
                    const tcp_nodelay: c_int = 1;
                    _ = std.posix.setsockopt(
                        connection.stream.handle,
                        std.posix.IPPROTO.TCP,
                        std.posix.TCP.NODELAY,
                        &std.mem.toBytes(tcp_nodelay),
                    ) catch {};

                    // Set TCP_QUICKACK for faster ACKs
                    if (@hasDecl(std.posix.TCP, "QUICKACK")) {
                        const quickack: c_int = 1;
                        _ = std.posix.setsockopt(
                            connection.stream.handle,
                            std.posix.IPPROTO.TCP,
                            std.posix.TCP.QUICKACK,
                            &std.mem.toBytes(quickack),
                        ) catch {};
                    }



                    // Route to NUMA-local threadpool (epoll-based)
                    const node_idx = listener_idx % topology.nodes.len;
                    thread_pools[node_idx].spawn(connection) catch |err| {
                        std.log.err("Failed to add connection to epoll: {}", .{err});
                        _ = active_connections.fetchSub(1, .monotonic);
                        connection.stream.close();
                        break;
                    };

                    connection_count += 1;

                    if (connection_count % 10000 == 0) {
                        std.log.info("Processed {} connections ({} active, {} rejected)", .{ connection_count, active_connections.load(.monotonic), rejected_connections });
                    }
                    break; // Successfully processed one connection, try next
                }
            }
        }
    }

    std.log.info("Shutting down gracefully...", .{});

    // Signal all thread pools to shutdown
    for (thread_pools) |*pool| {
        pool.shutdown.store(true, .release);
    }

    // Give workers time to finish current tasks
    std.Thread.sleep(100_000_000); // 100ms

    std.log.info("Total connections processed: {}", .{connection_count});
}

// Import tests
test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("numa.zig");
    _ = @import("config.zig");
    _ = @import("pool_lockfree.zig");
    _ = @import("handler_registry.zig");
}
