/// Event-driven thread pool using epoll
/// Replaces blocking threadpool with non-blocking event-driven workers
///
/// Generic over Registry type to eliminate function pointer indirection on hot path.
/// Each worker reuses a thread-local arena allocator (reset per request, not recreated).

const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const numa = @import("numa.zig");
const EpollWorkerMod = @import("epoll_worker.zig");

pub const EpollThreadPool = struct {
    allocator: Allocator,
    node_id: usize,
    workers: []EpollWorkerMod.EpollWorker,
    threads: []Thread,
    shutdown: std.atomic.Value(bool),
    handler_registry_ptr: *anyopaque,
    handler_dispatch_fn: *const fn (*anyopaque, fd: std.posix.fd_t, msg_type: u8, data: []const u8, response_buf: []u8) ?[]const u8,
    next_worker: std.atomic.Value(usize),

    pub fn init(
        allocator: Allocator,
        node: numa.NumaNode,
        num_workers: usize,
        handler_registry: anytype,
        active_connections: ?*std.atomic.Value(usize),
    ) !EpollThreadPool {
        // Create dispatch function that wraps the handler registry.
        // Uses a thread-local arena allocator that is reset per request
        // instead of creating/destroying one each time (~100-500ns saved per request).
        const dispatch_fn = struct {
            threadlocal var tl_arena: ?std.heap.ArenaAllocator = null;

            fn dispatch(
                registry_ptr: *anyopaque,
                fd: std.posix.fd_t,
                msg_type: u8,
                data: []const u8,
                response_buf: []u8,
            ) ?[]const u8 {
                _ = fd;
                const registry: @TypeOf(handler_registry) = @ptrCast(@alignCast(registry_ptr));

                // Reuse thread-local arena — reset() is O(1), no mmap/munmap
                if (tl_arena == null) {
                    tl_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                }
                defer _ = tl_arena.?.reset(.retain_capacity);
                const alloc = tl_arena.?.allocator();

                // Dispatch to appropriate handler using registry.handle
                const response = registry.handle(msg_type, data, response_buf, alloc);
                if (response.isOk()) {
                    return response.data;
                }
                return null;
            }
        }.dispatch;

        var pool = EpollThreadPool{
            .allocator = allocator,
            .node_id = node.id,
            .workers = try allocator.alloc(EpollWorkerMod.EpollWorker, num_workers),
            .threads = try allocator.alloc(Thread, num_workers),
            .shutdown = std.atomic.Value(bool).init(false),
            .handler_registry_ptr = @ptrCast(handler_registry),
            .handler_dispatch_fn = dispatch_fn,
            .next_worker = std.atomic.Value(usize).init(0),
        };

        std.log.info("Creating epoll threadpool for NUMA node {} with {} workers", .{ node.id, num_workers });

        // Initialize workers
        for (pool.workers, 0..) |*worker, i| {
            const cpu_id = node.cpus[i % node.cpus.len];
            worker.* = try EpollWorkerMod.EpollWorker.init(
                allocator,
                i,
                cpu_id,
                pool.handler_registry_ptr,
                pool.handler_dispatch_fn,
                &pool.shutdown,
                active_connections,
            );
        }

        // Spawn worker threads
        for (pool.workers, 0..) |*worker, i| {
            pool.threads[i] = try Thread.spawn(.{}, EpollWorkerMod.EpollWorker.run, .{worker});
        }

        return pool;
    }

    pub fn spawn(self: *EpollThreadPool, connection: net.Server.Connection) !void {
        // Use fd-based hashing for connection affinity (cache-friendly)
        // Same connection always routes to same worker → same CPU core
        // This keeps connection data in that core's L1/L2 cache
        const fd: usize = @intCast(connection.stream.handle);
        const worker_idx = fd % self.workers.len;
        try self.workers[worker_idx].addConnection(connection.stream.handle);
    }

    pub fn deinit(self: *EpollThreadPool) void {
        self.shutdown.store(true, .release);

        // Wait for all threads
        for (self.threads) |thread| {
            thread.join();
        }

        // Clean up workers
        for (self.workers) |*worker| {
            worker.deinit();
        }

        self.allocator.free(self.workers);
        self.allocator.free(self.threads);

        std.log.info("Epoll threadpool for NUMA node {} shut down", .{self.node_id});
    }

    pub fn getStats(self: *EpollThreadPool) Stats {
        var total_requests: u64 = 0;
        var total_connections: usize = 0;

        for (self.workers) |*worker| {
            total_requests += worker.requests_processed.load(.monotonic);
            total_connections += worker.connections.count();
        }

        return .{
            .total_requests = total_requests,
            .active_connections = total_connections,
            .num_workers = self.workers.len,
        };
    }

    pub const Stats = struct {
        total_requests: u64,
        active_connections: usize,
        num_workers: usize,
    };
};
