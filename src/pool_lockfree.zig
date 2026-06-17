const std = @import("std");
const Allocator = std.mem.Allocator;

/// Tagged pointer to prevent ABA problem in lock-free stack.
/// Uses 32-bit tag for ABA protection (4B increments before wraparound).
/// TODO(correctness): At 1M ops/sec the tag wraps in ~72 minutes. For long-running
/// servers, consider 48-bit tag + 16-bit index (limits pool to 65K entries) or
/// use platform-specific 128-bit CAS (CMPXCHG16B / CASP).
const TaggedNodePtr = packed struct {
    ptr: u32, // Index into nodes array (supports up to 4B entries)
    tag: u32, // Version counter (4B increments before wraparound)

    fn init(ptr: u32, tag: u32) TaggedNodePtr {
        return .{ .ptr = ptr, .tag = tag };
    }

    fn toU64(self: TaggedNodePtr) u64 {
        return (@as(u64, self.tag) << 32) | self.ptr;
    }

    fn fromU64(val: u64) TaggedNodePtr {
        return .{
            .ptr = @truncate(val & 0xFFFF_FFFF),
            .tag = @truncate(val >> 32),
        };
    }
};

/// Lock-free object pool using atomic operations with tagged pointers
/// NO SYSCALLS in the hot path (acquire/release)
/// Uses tagged CAS to prevent ABA problem
pub fn LockFreePool(comptime T: type) type {
    return struct {
        const Self = @This();

        const INVALID_INDEX: usize = std.math.maxInt(u32);

        /// Node in the lock-free stack
        const Node = struct {
            data: T,
            next_idx: std.atomic.Value(usize), // Index into nodes array, or INVALID_INDEX

            fn init(data: T) Node {
                return .{
                    .data = data,
                    .next_idx = std.atomic.Value(usize).init(INVALID_INDEX),
                };
            }
        };

        allocator: Allocator,
        nodes: []Node,
        head: std.atomic.Value(u64), // Tagged pointer (index + version)

        /// Statistics (atomic counters)
        total_acquires: std.atomic.Value(u64),
        total_releases: std.atomic.Value(u64),
        failed_acquires: std.atomic.Value(u64),
        available: std.atomic.Value(usize), // Approximate count

        pub fn init(allocator: Allocator, capacity: usize) !Self {
            // Allocate all nodes upfront
            const nodes = try allocator.alloc(Node, capacity);
            errdefer allocator.free(nodes);

            // Initialize each node
            for (nodes) |*node| {
                if (@hasDecl(T, "initPooled")) {
                    node.* = Node.init(T.initPooled());
                } else {
                    node.* = Node.init(std.mem.zeroes(T));
                }
            }

            // Build lock-free stack (all nodes initially available)
            // Link nodes: 0 -> 1 -> 2 -> ... -> (capacity-1) -> INVALID
            var i = nodes.len;
            while (i > 0) {
                i -= 1;
                const next_idx = if (i + 1 < nodes.len) i + 1 else INVALID_INDEX;
                nodes[i].next_idx.store(next_idx, .release);
            }

            // Head points to first node (index 0) with tag 0
            const initial_head = TaggedNodePtr.init(0, 0);

            return Self{
                .allocator = allocator,
                .nodes = nodes,
                .head = std.atomic.Value(u64).init(initial_head.toU64()),
                .total_acquires = std.atomic.Value(u64).init(0),
                .total_releases = std.atomic.Value(u64).init(0),
                .failed_acquires = std.atomic.Value(u64).init(0),
                .available = std.atomic.Value(usize).init(capacity),
            };
        }

        pub fn deinit(self: *Self) void {
            // Deinit objects if they have a deinitPooled() method
            if (@hasDecl(T, "deinitPooled")) {
                for (self.nodes) |*node| {
                    node.data.deinitPooled();
                }
            }

            self.allocator.free(self.nodes);
        }

        /// Maximum retries for CAS operations under contention
        /// Made public to allow tuning for specific workloads
        pub const DEFAULT_MAX_RETRIES = 10000; // Increased for high-contention scenarios

        /// Acquire an object from the pool (LOCK-FREE, NO SYSCALLS)
        pub fn acquire(self: *Self) !*T {
            _ = self.total_acquires.fetchAdd(1, .monotonic);

            var retry_count: usize = 0;
            const max_retries = DEFAULT_MAX_RETRIES;

            // Lock-free pop from stack using tagged CAS
            while (retry_count < max_retries) : (retry_count += 1) {
                // Load current head (tagged pointer)
                const head_val = self.head.load(.acquire);
                const current_head = TaggedNodePtr.fromU64(head_val);

                // Check if pool is empty
                if (current_head.ptr >= self.nodes.len) {
                    _ = self.failed_acquires.fetchAdd(1, .monotonic);
                    return error.PoolExhausted;
                }

                // Load next index from current head node
                const current_node = &self.nodes[current_head.ptr];
                const next_idx = current_node.next_idx.load(.acquire);

                // Create new head with incremented tag to prevent ABA
                // Cast to u32 since we now use 32-bit pointers
                const new_head = TaggedNodePtr.init(@intCast(next_idx), current_head.tag +% 1);

                // Try to atomically update head
                if (self.head.cmpxchgWeak(
                    head_val,
                    new_head.toU64(),
                    .acq_rel,
                    .acquire,
                )) |_| {
                    // CAS failed, another thread modified head
                    continue;
                }

                // CAS succeeded! We own current_node
                _ = self.available.fetchSub(1, .monotonic);

                // Reset the object if it has a reset() method
                if (@hasDecl(T, "reset")) {
                    current_node.data.reset();
                }

                return &current_node.data;
            }

            // Failed after max retries (extreme contention)
            _ = self.failed_acquires.fetchAdd(1, .monotonic);
            return error.PoolExhausted;
        }

        /// Release an object back to the pool (LOCK-FREE, NO SYSCALLS)
        pub fn release(self: *Self, obj: *T) void {
            _ = self.total_releases.fetchAdd(1, .monotonic);

            // Find the node containing this object and its index
            const node: *Node = @fieldParentPtr("data", obj);
            const node_ptr = @intFromPtr(node);
            const base_ptr = @intFromPtr(self.nodes.ptr);

            // Bounds check to prevent use-after-free vulnerability
            if (node_ptr < base_ptr) {
                std.log.err("Invalid object released: pointer below pool base", .{});
                return;
            }

            const offset = node_ptr - base_ptr;
            if (offset % @sizeOf(Node) != 0) {
                std.log.err("Invalid object released: misaligned pointer", .{});
                return;
            }

            const node_idx = offset / @sizeOf(Node);
            if (node_idx >= self.nodes.len) {
                std.log.err("Invalid object released: index {} >= capacity {}", .{node_idx, self.nodes.len});
                return;
            }

            // Reset object before returning to pool
            if (@hasDecl(T, "reset")) {
                obj.reset();
            } else {
                obj.* = std.mem.zeroes(T);
            }

            var retry_count: usize = 0;
            const max_retries = DEFAULT_MAX_RETRIES;

            // Lock-free push to stack using tagged CAS
            while (retry_count < max_retries) : (retry_count += 1) {
                // Load current head
                const head_val = self.head.load(.acquire);
                const current_head = TaggedNodePtr.fromU64(head_val);

                // Set our next to current head index
                node.next_idx.store(current_head.ptr, .release);

                // Create new head pointing to our node with incremented tag
                // Cast node_idx to u32 for 32-bit tagged pointer
                const new_head = TaggedNodePtr.init(@intCast(node_idx), current_head.tag +% 1);

                // Try to atomically update head to our node
                if (self.head.cmpxchgWeak(
                    head_val,
                    new_head.toU64(),
                    .acq_rel,
                    .acquire,
                )) |_| {
                    // CAS failed, retry
                    continue;
                }

                // CAS succeeded! Node is back in the pool
                _ = self.available.fetchAdd(1, .monotonic);
                return;
            }

            // Failed to release after max retries — extreme contention or bug.
            // Log and leak the object rather than crashing the process.
            std.log.err("Failed to release object to pool after {d} retries — leaking to avoid crash", .{max_retries});
            return;
        }

        pub fn stats(self: *Self) PoolStats {
            // Use atomic counter for approximate available count
            const avail = self.available.load(.monotonic);

            return .{
                .total = self.nodes.len,
                .available = avail,
                .in_use = self.nodes.len -| avail, // Saturating subtraction
                .total_acquires = self.total_acquires.load(.monotonic),
                .total_releases = self.total_releases.load(.monotonic),
                .failed_acquires = self.failed_acquires.load(.monotonic),
            };
        }
    };
}

pub const PoolStats = struct {
    total: usize,
    available: usize,
    in_use: usize,
    total_acquires: u64,
    total_releases: u64,
    failed_acquires: u64,
};

/// Lock-free buffer pool for fixed-size buffers
pub fn LockFreeBufferPool(comptime buffer_size: usize) type {
    const Buffer = struct {
        data: [buffer_size]u8,
        len: usize,

        pub fn initPooled() @This() {
            return .{
                .data = undefined,
                .len = 0,
            };
        }

        pub fn reset(self: *@This()) void {
            self.len = 0;
        }

        pub fn write(self: *@This(), bytes: []const u8) !void {
            if (bytes.len > buffer_size) return error.BufferFull;
            @memcpy(self.data[0..bytes.len], bytes);
            self.len = bytes.len;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.data[0..self.len];
        }

        pub fn sliceMut(self: *@This()) []u8 {
            return self.data[0..self.len];
        }
    };

    return LockFreePool(Buffer);
}

/// Per-CPU object pool (eliminates contention)
/// Each CPU has its own pool, no synchronization needed on same CPU
pub fn PerCpuPool(comptime T: type, comptime max_cpus: usize) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        pools: [max_cpus]LockFreePool(T),
        cpu_count: usize,

        pub fn init(allocator: Allocator, capacity_per_cpu: usize, cpu_count: usize) !Self {
            var pools: [max_cpus]LockFreePool(T) = undefined;
            var initialized: usize = 0;
            errdefer {
                for (0..initialized) |i| {
                    pools[i].deinit();
                }
            }

            for (0..cpu_count) |i| {
                pools[i] = try LockFreePool(T).init(allocator, capacity_per_cpu);
                initialized += 1;
            }

            return Self{
                .allocator = allocator,
                .pools = pools,
                .cpu_count = cpu_count,
            };
        }

        pub fn deinit(self: *Self) void {
            for (0..self.cpu_count) |i| {
                self.pools[i].deinit();
            }
        }

        /// Acquire from current CPU's pool (minimal contention)
        pub fn acquire(self: *Self) !*T {
            const cpu_id = getCurrentCpu();
            const pool_idx = cpu_id % self.cpu_count;
            return self.pools[pool_idx].acquire();
        }

        /// Release to the pool that owns this object (found via pointer arithmetic)
        pub fn release(self: *Self, obj: *T) void {
            const Node = LockFreePool(T).Node;
            const node: *Node = @fieldParentPtr("data", obj);
            const node_ptr = @intFromPtr(node);

            // Find which pool owns this node by checking pointer ranges
            for (0..self.cpu_count) |i| {
                const base_ptr = @intFromPtr(self.pools[i].nodes.ptr);
                const end_ptr = base_ptr + self.pools[i].nodes.len * @sizeOf(Node);
                if (node_ptr >= base_ptr and node_ptr < end_ptr) {
                    self.pools[i].release(obj);
                    return;
                }
            }

            std.log.err("PerCpuPool: released object does not belong to any pool", .{});
        }

        pub fn aggregateStats(self: *Self) PoolStats {
            var total_stats = PoolStats{
                .total = 0,
                .available = 0,
                .in_use = 0,
                .total_acquires = 0,
                .total_releases = 0,
                .failed_acquires = 0,
            };

            for (0..self.cpu_count) |i| {
                const stats = self.pools[i].stats();
                total_stats.total += stats.total;
                total_stats.available += stats.available;
                total_stats.in_use += stats.in_use;
                total_stats.total_acquires += stats.total_acquires;
                total_stats.total_releases += stats.total_releases;
                total_stats.failed_acquires += stats.failed_acquires;
            }

            return total_stats;
        }

        fn getCurrentCpu() usize {
            // Platform-specific CPU detection
            if (comptime @import("builtin").target.os.tag == .linux) {
                // Linux: Use getcpu() via VDSO (no syscall)
                var cpu: usize = 0;
                var node: usize = 0;
                _ = std.os.linux.getcpu(&cpu, &node);
                return cpu;
            }

            // Fallback: Use thread ID with better distribution
            // Hash the thread ID to avoid clustering when thread IDs are sequential
            const tid = std.Thread.getCurrentId();
            // Simple multiplicative hash for better distribution
            return (tid *% 0x9e3779b97f4a7c15) >> 56; // Use upper 8 bits for range 0-255
        }
    };
}

// Tests
test "lock-free pool basic" {
    const allocator = std.testing.allocator;

    const TestObj = struct {
        value: u64,

        pub fn reset(self: *@This()) void {
            self.value = 0;
        }
    };

    var pool = try LockFreePool(TestObj).init(allocator, 10);
    defer pool.deinit();

    // Acquire and release
    var obj1 = try pool.acquire();
    obj1.value = 42;

    pool.release(obj1);

    const obj2 = try pool.acquire();
    try std.testing.expectEqual(@as(u64, 0), obj2.value); // Reset to 0
}

test "lock-free pool concurrent" {
    const allocator = std.testing.allocator;

    const TestObj = struct {
        value: u64,

        pub fn reset(self: *@This()) void {
            self.value = 0;
        }
    };

    var pool = try LockFreePool(TestObj).init(allocator, 100);
    defer pool.deinit();

    const Worker = struct {
        pool: *LockFreePool(TestObj),

        fn run(self: *@This()) void {
            for (0..1000) |_| {
                var obj = self.pool.acquire() catch continue;
                obj.value = 123;
                self.pool.release(obj);
            }
        }
    };

    // Spawn multiple threads
    var threads: [4]std.Thread = undefined;
    var workers: [4]Worker = undefined;

    for (&threads, &workers) |*thread, *worker| {
        worker.* = .{ .pool = &pool };
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }

    for (threads) |thread| {
        thread.join();
    }

    const stats = pool.stats();
    std.debug.print("Stats: {} available, {} total ops\n", .{
        stats.available,
        stats.total_acquires,
    });

    // All objects should be back in pool
    try std.testing.expectEqual(@as(usize, 100), stats.available);
}

test "per-CPU pool" {
    const allocator = std.testing.allocator;

    const TestObj = struct {
        value: u64,
        pub fn reset(self: *@This()) void {
            self.value = 0;
        }
    };

    var pool = try PerCpuPool(TestObj, 16).init(allocator, 10, 4);
    defer pool.deinit();

    var obj = try pool.acquire();
    obj.value = 99;
    pool.release(obj);

    const stats = pool.aggregateStats();
    try std.testing.expectEqual(@as(usize, 40), stats.total); // 10 * 4 CPUs
}

test "lock-free buffer pool" {
    const allocator = std.testing.allocator;

    var pool = try LockFreeBufferPool(1024).init(allocator, 10);
    defer pool.deinit();

    var buf = try pool.acquire();
    try buf.write("Hello, lock-free!");

    try std.testing.expectEqualStrings("Hello, lock-free!", buf.slice());

    pool.release(buf);

    const buf2 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 0), buf2.len); // Reset
}
