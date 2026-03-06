const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const NumaNode = struct {
    id: usize,
    cpus: []u32,
    memory_mb: usize,

    pub fn deinit(self: *NumaNode, allocator: Allocator) void {
        allocator.free(self.cpus);
    }
};

pub const NumaTopology = struct {
    nodes: []NumaNode,
    total_cpus: usize,
    allocator: Allocator,

    pub fn detect(allocator: Allocator) !NumaTopology {
        // Try to detect NUMA nodes, fall back to single node if not available
        const node_ids = detectNumaNodes(allocator) catch |err| {
            std.log.warn("NUMA detection failed ({}), falling back to single node", .{err});
            return try createFallbackTopology(allocator);
        };
        defer allocator.free(node_ids);

        if (node_ids.len == 0) {
            return try createFallbackTopology(allocator);
        }

        var nodes = try allocator.alloc(NumaNode, node_ids.len);
        errdefer allocator.free(nodes);

        var total_cpus: usize = 0;

        for (node_ids, 0..) |node_id, i| {
            const cpus = try parseCpuList(allocator, node_id);
            errdefer allocator.free(cpus);

            nodes[i] = NumaNode{
                .id = node_id,
                .cpus = cpus,
                .memory_mb = 0, // Optional: could read from meminfo
            };

            total_cpus += cpus.len;
        }

        std.log.info("Detected {} NUMA nodes with {} total CPUs", .{ nodes.len, total_cpus });
        for (nodes) |node| {
            std.log.info("  Node {}: {} CPUs", .{ node.id, node.cpus.len });
        }

        return NumaTopology{
            .nodes = nodes,
            .total_cpus = total_cpus,
            .allocator = allocator,
        };
    }

    fn createFallbackTopology(allocator: Allocator) !NumaTopology {
        const cpu_count = try std.Thread.getCpuCount();
        var cpus = try allocator.alloc(u32, cpu_count);
        errdefer allocator.free(cpus);

        for (0..cpu_count) |i| {
            cpus[i] = @intCast(i);
        }

        var nodes = try allocator.alloc(NumaNode, 1);
        errdefer allocator.free(nodes);

        nodes[0] = NumaNode{
            .id = 0,
            .cpus = cpus,
            .memory_mb = 0,
        };

        std.log.info("Using fallback: 1 NUMA node with {} CPUs", .{cpu_count});

        return NumaTopology{
            .nodes = nodes,
            .total_cpus = cpu_count,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NumaTopology) void {
        for (self.nodes) |*node| {
            node.deinit(self.allocator);
        }
        self.allocator.free(self.nodes);
    }

    pub fn getCpusForNode(self: NumaTopology, node_id: usize) ?[]const u32 {
        for (self.nodes) |node| {
            if (node.id == node_id) {
                return node.cpus;
            }
        }
        return null;
    }

    pub fn getNodeForCpu(self: NumaTopology, cpu_id: u32) ?usize {
        for (self.nodes) |node| {
            for (node.cpus) |cpu| {
                if (cpu == cpu_id) {
                    return node.id;
                }
            }
        }
        return null;
    }
};

fn detectNumaNodes(allocator: Allocator) ![]usize {
    const online_path = "/sys/devices/system/node/online";
    const file = std.fs.openFileAbsolute(online_path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    var buf: [1024]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    const content = std.mem.trim(u8, buf[0..bytes_read], &std.ascii.whitespace);

    return try parseNodeList(allocator, content);
}

fn parseNodeList(allocator: Allocator, input: []const u8) ![]usize {
    var result = std.ArrayList(usize){};
    errdefer result.deinit(allocator);

    var parts = std.mem.splitScalar(u8, input, ',');
    while (parts.next()) |part| {
        if (std.mem.indexOfScalar(u8, part, '-')) |dash_idx| {
            // Range: "0-1"
            const start = try std.fmt.parseInt(usize, part[0..dash_idx], 10);
            const end = try std.fmt.parseInt(usize, part[dash_idx + 1 ..], 10);

            var i = start;
            while (i <= end) : (i += 1) {
                try result.append(allocator, i);
            }
        } else {
            // Single value: "0"
            const val = try std.fmt.parseInt(usize, part, 10);
            try result.append(allocator, val);
        }
    }

    return result.toOwnedSlice(allocator);
}

fn parseCpuList(allocator: Allocator, node_id: usize) ![]u32 {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/sys/devices/system/node/node{d}/cpulist", .{node_id});

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    var buf: [1024]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    const content = std.mem.trim(u8, buf[0..bytes_read], &std.ascii.whitespace);

    return try parseRangeList(allocator, content);
}

fn parseRangeList(allocator: Allocator, input: []const u8) ![]u32 {
    var result = std.ArrayList(u32){};
    errdefer result.deinit(allocator);

    var parts = std.mem.splitScalar(u8, input, ',');
    while (parts.next()) |part| {
        if (std.mem.indexOfScalar(u8, part, '-')) |dash_idx| {
            // Range: "0-15"
            const start = try std.fmt.parseInt(u32, part[0..dash_idx], 10);
            const end = try std.fmt.parseInt(u32, part[dash_idx + 1 ..], 10);

            var i = start;
            while (i <= end) : (i += 1) {
                try result.append(allocator, i);
            }
        } else {
            // Single value: "4"
            const val = try std.fmt.parseInt(u32, part, 10);
            try result.append(allocator, val);
        }
    }

    return result.toOwnedSlice(allocator);
}

// CPU affinity functions
pub fn pinThreadToCpu(cpu_id: u32) !void {
    var cpuset: posix.cpu_set_t = undefined;
    cpuSetZero(&cpuset);
    cpuSetAdd(&cpuset, cpu_id);

    const tid: i32 = 0; // 0 means current thread
    try std.os.linux.sched_setaffinity(tid, &cpuset);
}

pub fn cpuSetZero(set: *posix.cpu_set_t) void {
    @memset(std.mem.asBytes(set), 0);
}

pub fn cpuSetAdd(set: *posix.cpu_set_t, cpu_id: u32) void {
    const element = cpu_id / (8 * @sizeOf(usize));
    const offset = cpu_id % (8 * @sizeOf(usize));

    // Bounds check to prevent buffer overflow
    // cpu_set_t is typically 128 bytes (1024 bits), supporting up to 1024 CPUs
    const max_element = @sizeOf(posix.cpu_set_t) / @sizeOf(usize);
    if (element >= max_element) {
        std.log.err("CPU ID {} exceeds cpu_set_t capacity (max {} CPUs)", .{
            cpu_id,
            max_element * 8 * @sizeOf(usize),
        });
        return; // Silently fail to prevent crash
    }

    set[element] |= (@as(usize, 1) << @intCast(offset));
}

pub fn getCurrentAffinity() posix.cpu_set_t {
    var cpuset: posix.cpu_set_t = undefined;
    const tid: i32 = 0;
    // sched_getaffinity returns usize (number of bytes written), not an error union
    _ = std.os.linux.sched_getaffinity(tid, @sizeOf(posix.cpu_set_t), &cpuset);
    return cpuset;
}

pub fn cpuSetCount(set: posix.cpu_set_t) usize {
    var count: usize = 0;
    for (0..128) |cpu| {
        const element = cpu / (8 * @sizeOf(usize));
        const offset = cpu % (8 * @sizeOf(usize));
        const is_set = (set[element] & (@as(usize, 1) << @intCast(offset))) != 0;
        if (is_set) count += 1;
    }
    return count;
}

// Tests
test "detect NUMA topology" {
    const allocator = std.testing.allocator;

    var topology = try NumaTopology.detect(allocator);
    defer topology.deinit();

    try std.testing.expect(topology.nodes.len > 0);
    try std.testing.expect(topology.total_cpus > 0);

    std.debug.print("\nDetected {} NUMA nodes, {} total CPUs\n", .{ topology.nodes.len, topology.total_cpus });

    for (topology.nodes) |node| {
        std.debug.print("  Node {}: {} CPUs\n", .{ node.id, node.cpus.len });
    }
}

test "CPU pinning" {
    var topology = try NumaTopology.detect(std.testing.allocator);
    defer topology.deinit();

    if (topology.total_cpus == 0) return error.SkipZigTest;

    const cpu = topology.nodes[0].cpus[0];
    try pinThreadToCpu(cpu);

    const affinity = getCurrentAffinity();
    const count = cpuSetCount(affinity);

    try std.testing.expect(count >= 1);
}
