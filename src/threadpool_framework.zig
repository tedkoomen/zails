/// Lock-free threadpool that uses the server framework's handler registry
/// This connects worker threads to user-defined handlers

const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const numa = @import("numa.zig");
const server_framework = @import("server_framework.zig");

pub const LockFreeThreadPool = struct {
    allocator: Allocator,
    node_id: usize,
    cpus: []const u32,
    workers: []WorkerThread,
    shutdown: std.atomic.Value(bool),
    handler_registry_ptr: *anyopaque,
    handler_dispatch_fn: *const fn (*anyopaque, net.Server.Connection) void,
    active_connections: ?*std.atomic.Value(usize), // Optional connection counter

    pub fn init(
        allocator: Allocator,
        node: numa.NumaNode,
        num_workers: usize,
        handler_registry: anytype,
        active_connections: ?*std.atomic.Value(usize),
    ) !LockFreeThreadPool {
        const dispatch_fn = struct {
            fn dispatch(registry_ptr: *anyopaque, connection: net.Server.Connection) void {
                const registry: @TypeOf(handler_registry) = @ptrCast(@alignCast(registry_ptr));
                server_framework.handleConnection(connection, registry);
            }
        }.dispatch;

        var pool = LockFreeThreadPool{
            .allocator = allocator,
            .node_id = node.id,
            .cpus = node.cpus,
            .workers = try allocator.alloc(WorkerThread, num_workers),
            .shutdown = std.atomic.Value(bool).init(false),
            .handler_registry_ptr = @ptrCast(handler_registry),
            .handler_dispatch_fn = dispatch_fn,
            .active_connections = active_connections,
        };

        std.log.info("Creating threadpool for NUMA node {} with {} workers", .{ node.id, num_workers });

        for (pool.workers, 0..) |*worker, i| {
            const cpu_id = node.cpus[i % node.cpus.len];

            worker.* = try WorkerThread.init(
                allocator,
                cpu_id,
                &pool,
                i,
            );
        }

        for (pool.workers) |*worker| {
            worker.thread = try Thread.spawn(.{}, WorkerThread.run, .{worker});
        }

        return pool;
    }

    pub fn spawn(self: *LockFreeThreadPool, connection: net.Server.Connection) !void {
        const worker_idx = selectWorker(self.workers.len);
        try self.workers[worker_idx].enqueue(connection);
    }

    threadlocal var worker_counter: usize = 0;

    fn selectWorker(worker_count: usize) usize {
        const idx = worker_counter;
        worker_counter = (worker_counter + 1) % worker_count;
        return idx;
    }

    pub fn deinit(self: *LockFreeThreadPool) void {
        self.shutdown.store(true, .release);

        for (self.workers) |*worker| {
            worker.thread.join();
            worker.deinit();
        }

        self.allocator.free(self.workers);
        std.log.info("Threadpool for NUMA node {} shut down", .{self.node_id});
    }
};

// Tagged pointer to prevent ABA problem
// Upper 16 bits = tag/version, lower 48 bits = value
const TaggedUsize = struct {
    const TAG_BITS = 16;
    const VALUE_MASK = (1 << (64 - TAG_BITS)) - 1;

    raw: std.atomic.Value(u64),

    fn init(value: usize) TaggedUsize {
        return .{ .raw = std.atomic.Value(u64).init(value & VALUE_MASK) };
    }

    inline fn load(self: *const TaggedUsize, comptime ordering: std.builtin.AtomicOrder) struct { value: usize, tag: u16 } {
        const raw_val = self.raw.load(ordering);
        return .{
            .value = @truncate(raw_val & VALUE_MASK),
            .tag = @truncate(raw_val >> (64 - TAG_BITS)),
        };
    }

    inline fn store(self: *TaggedUsize, value: usize, tag: u16, comptime ordering: std.builtin.AtomicOrder) void {
        const raw_val = (@as(u64, tag) << (64 - TAG_BITS)) | (value & VALUE_MASK);
        self.raw.store(raw_val, ordering);
    }

    inline fn cmpxchg(
        self: *TaggedUsize,
        expected_value: usize,
        expected_tag: u16,
        new_value: usize,
        new_tag: u16,
        comptime success: std.builtin.AtomicOrder,
        comptime failure: std.builtin.AtomicOrder,
    ) ?struct { value: usize, tag: u16 } {
        const expected = (@as(u64, expected_tag) << (64 - TAG_BITS)) | (expected_value & VALUE_MASK);
        const new = (@as(u64, new_tag) << (64 - TAG_BITS)) | (new_value & VALUE_MASK);

        if (self.raw.cmpxchgWeak(expected, new, success, failure)) |actual| {
            return .{
                .value = @truncate(actual & VALUE_MASK),
                .tag = @truncate(actual >> (64 - TAG_BITS)),
            };
        }
        return null;
    }
};

const LockFreeDeque = struct {
    // Work queue capacity per worker (8192 = ~320KB per worker)
    // With 8 workers: 65,536 total queue capacity
    const capacity = 8192;

    items: [capacity]?net.Server.Connection,
    top: TaggedUsize,
    bottom: TaggedUsize,

    fn init() LockFreeDeque {
        return .{
            .items = [_]?net.Server.Connection{null} ** capacity,
            .top = TaggedUsize.init(0),
            .bottom = TaggedUsize.init(0),
        };
    }

    fn push(self: *LockFreeDeque, connection: net.Server.Connection) !void {
        const b = self.bottom.load(.acquire);
        const t = self.top.load(.acquire);

        // Explicit bounds check to prevent integer overflow and buffer overrun
        const queue_size = b.value -% t.value;
        if (queue_size >= capacity) {
            return error.QueueFull;
        }

        const slot_idx = b.value % capacity;
        self.items[slot_idx] = connection;
        // Release ordering in bottom.store ensures visibility of the item write

        self.bottom.store(b.value +% 1, b.tag +% 1, .release);
    }

    fn pop(self: *LockFreeDeque) ?net.Server.Connection {
        const b = self.bottom.load(.acquire);
        if (b.value == 0) return null;

        const new_bottom = b.value -% 1;
        // Use .seq_cst for proper synchronization with stealers
        self.bottom.store(new_bottom, b.tag +% 1, .seq_cst);

        // Use .seq_cst to match bottom.store memory ordering
        const t = self.top.load(.seq_cst);

        if (t.value <= new_bottom) {
            const item = self.items[new_bottom % capacity];
            if (t.value == new_bottom) {
                // Last element - need to compete with stealers
                if (self.top.cmpxchg(t.value, t.tag, t.value +% 1, t.tag +% 1, .seq_cst, .seq_cst)) |_| {
                    // Lost race with stealer - item was stolen
                    // Restore bottom to indicate queue is empty
                    self.bottom.store(t.value, b.tag +% 2, .seq_cst);
                    return null;
                }
                // Won the race - we got the item, update bottom
                self.bottom.store(t.value, b.tag +% 2, .seq_cst);
            }
            return item;
        } else {
            // Queue was empty - restore bottom
            self.bottom.store(t.value, b.tag +% 2, .seq_cst);
            return null;
        }
    }

    fn steal(self: *LockFreeDeque) ?net.Server.Connection {
        var retry_count: usize = 0;
        while (retry_count < 100) : (retry_count += 1) {
            const t = self.top.load(.acquire);
            // Acquire ordering ensures we see consistent bottom
            const b = self.bottom.load(.acquire);

            if (t.value >= b.value) return null;

            const item = self.items[t.value % capacity];

            if (self.top.cmpxchg(t.value, t.tag, t.value +% 1, t.tag +% 1, .seq_cst, .acquire)) |_| {
                // CAS failed, retry
                continue;
            }

            return item;
        }
        return null; // Give up after retries
    }
};

const WorkerThread = struct {
    thread: Thread,
    cpu_id: u32,
    worker_id: usize,
    pool: *LockFreeThreadPool,
    queue: LockFreeDeque,
    tasks_processed: std.atomic.Value(u64),

    fn init(allocator: Allocator, cpu_id: u32, pool: *LockFreeThreadPool, worker_id: usize) !WorkerThread {
        _ = allocator;
        return WorkerThread{
            .thread = undefined,
            .cpu_id = cpu_id,
            .worker_id = worker_id,
            .pool = pool,
            .queue = LockFreeDeque.init(),
            .tasks_processed = std.atomic.Value(u64).init(0),
        };
    }

    fn deinit(self: *WorkerThread) void {
        _ = self;
    }

    fn enqueue(self: *WorkerThread, connection: net.Server.Connection) !void {
        try self.queue.push(connection);
    }

    fn run(self: *WorkerThread) void {
        numa.pinThreadToCpu(self.cpu_id) catch |err| {
            std.log.err("Worker {} failed to pin to CPU {}: {}", .{ self.worker_id, self.cpu_id, err });
        };

        std.log.debug("Worker {} pinned to CPU {} on NUMA node {}", .{
            self.worker_id,
            self.cpu_id,
            self.pool.node_id,
        });

        // Set worker ID for metric tracking
        server_framework.setWorkerID(@intCast(self.worker_id));

        var spin_count: usize = 0;
        const max_spins_before_yield = 100;
        const max_yields_before_sleep = 10;
        var yield_count: usize = 0;

        while (!self.pool.shutdown.load(.acquire)) {
            if (self.queue.pop()) |connection| {
                spin_count = 0;
                yield_count = 0;
                _ = self.tasks_processed.fetchAdd(1, .monotonic);

                // Use server framework's handler (routes to user handlers)
                self.pool.handler_dispatch_fn(self.pool.handler_registry_ptr, connection);

                // Decrement active connection count if tracking
                if (self.pool.active_connections) |counter| {
                    _ = counter.fetchSub(1, .monotonic);
                }
                continue;
            }

            if (self.trySteal()) |connection| {
                spin_count = 0;
                yield_count = 0;
                _ = self.tasks_processed.fetchAdd(1, .monotonic);

                self.pool.handler_dispatch_fn(self.pool.handler_registry_ptr, connection);

                // Decrement active connection count if tracking
                if (self.pool.active_connections) |counter| {
                    _ = counter.fetchSub(1, .monotonic);
                }
                continue;
            }

            // Hybrid backoff: spin -> yield -> sleep
            if (spin_count < max_spins_before_yield) {
                // Fast path: just spin with hints
                for (0..@min(16, max_spins_before_yield - spin_count)) |_| {
                    std.atomic.spinLoopHint();
                }
                spin_count += 16;
            } else if (yield_count < max_yields_before_sleep) {
                // Medium path: yield to scheduler
                std.Thread.yield() catch {};
                yield_count += 1;
            } else {
                // Slow path: sleep briefly
            // For microsecond-latency targets, 1ms is too long. Use adaptive sleep.
                std.Thread.sleep(100_000); // 100µs (more suitable for low-latency)
                // Reset counters to try spinning again
                spin_count = 0;
                yield_count = 0;
            }
        }

        std.log.debug("Worker {} shutting down (processed: {} tasks)", .{
            self.worker_id,
            self.tasks_processed.load(.monotonic),
        });
    }

    fn trySteal(self: *WorkerThread) ?net.Server.Connection {
        if (self.pool.workers.len <= 1) return null;

        // Try random victim first, then round-robin
        const victim_id = (self.worker_id + 1 + (wyrand() % (self.pool.workers.len - 1))) % self.pool.workers.len;
        if (self.pool.workers[victim_id].queue.steal()) |conn| {
            return conn;
        }

        // If that failed, try neighbors
        for (1..@min(4, self.pool.workers.len)) |offset| {
            const neighbor_id = (self.worker_id + offset) % self.pool.workers.len;
            if (neighbor_id == self.worker_id) continue;
            if (self.pool.workers[neighbor_id].queue.steal()) |conn| {
                return conn;
            }
        }

        return null;
    }

    threadlocal var rng_state: u64 = undefined;
    threadlocal var rng_initialized: bool = false;

    // WyRand - fast, high-quality PRNG
    fn wyrand() usize {
        if (!rng_initialized) {
            // Better seed mixing
            const tid: u64 = @intCast(std.Thread.getCurrentId());
            const timestamp = std.time.nanoTimestamp();
            // Handle negative timestamps explicitly instead of wrapping
            const time: u64 = if (timestamp >= 0) @intCast(timestamp) else 0;
            rng_state = tid *% @as(u64, 0x9e3779b97f4a7c15) ^ time;
            rng_initialized = true;
        }

        rng_state +%= @as(u64, 0xa0761d6478bd642f);
        const mul: u128 = @as(u128, rng_state) * @as(u128, rng_state ^ @as(u64, 0xe7037ed1a0b428db));
        rng_state = @truncate((mul >> 64) ^ mul);
        return @intCast(rng_state);
    }
};
