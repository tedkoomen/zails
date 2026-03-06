/// Performance profiling utilities for Zails
/// Provides tracing, flame graph support, and performance counters

const std = @import("std");
const builtin = @import("builtin");

/// Performance counter using CPU timestamp counter (TSC)
pub const PerfCounter = struct {
    start: u64,

    pub fn start() PerfCounter {
        return .{ .start = rdtsc() };
    }

    pub fn elapsed(self: PerfCounter) u64 {
        return rdtsc() - self.start;
    }

    pub fn elapsedNs(self: PerfCounter) u64 {
        // Assume 3GHz CPU (adjust based on your hardware)
        const cycles = self.elapsed();
        return @divTrunc(cycles * 1000, 3000); // cycles -> nanoseconds
    }

    pub fn elapsedUs(self: PerfCounter) u64 {
        return @divTrunc(self.elapsedNs(), 1000);
    }
};

/// Read CPU timestamp counter
/// NOTE: On x86_64, returns actual CPU cycle count via RDTSC instruction.
/// On other architectures, falls back to nanosecond timestamp (not cycle-accurate).
inline fn rdtsc() u64 {
    if (comptime builtin.cpu.arch == .x86_64) {
        var lo: u32 = undefined;
        var hi: u32 = undefined;
        asm volatile ("rdtsc"
            : [lo] "={eax}" (&lo),
              [hi] "={edx}" (&hi),
        );
        return (@as(u64, hi) << 32) | @as(u64, lo);
    } else {
        // Fallback to monotonic timestamp (not cycle-accurate, but monotonic)
        const timestamp = std.time.nanoTimestamp();
        // Handle negative timestamps properly (unlikely but possible on some systems)
        if (timestamp < 0) {
            return 0;
        }
        return @intCast(timestamp);
    }
}

/// Trace span for profiling
pub const TraceSpan = struct {
    name: []const u8,
    start_time: i64,
    parent: ?*TraceSpan,

    pub fn begin(name: []const u8, parent: ?*TraceSpan) TraceSpan {
        return .{
            .name = name,
            .start_time = std.time.microTimestamp(),
            .parent = parent,
        };
    }

    pub fn end(self: *TraceSpan) i64 {
        const duration = std.time.microTimestamp() - self.start_time;

        // Optionally log or export to tracing backend
        if (comptime builtin.mode == .Debug) {
            std.log.debug("[TRACE] {s}: {}µs", .{ self.name, duration });
        }

        return duration;
    }
};

/// CPU performance counters (Linux perf_event)
pub const CpuCounters = struct {
    instructions: u64,
    cycles: u64,
    cache_misses: u64,
    branch_misses: u64,

    pub fn read() CpuCounters {
        // This is a placeholder - actual implementation would use perf_event_open
        // For now, return zeros
        return .{
            .instructions = 0,
            .cycles = 0,
            .cache_misses = 0,
            .branch_misses = 0,
        };
    }
};

/// Sampling profiler for flame graphs
pub const SamplingProfiler = struct {
    samples: std.ArrayList(Sample),
    allocator: std.mem.Allocator,

    const Sample = struct {
        timestamp: i64,
        stack_trace: [32]usize,
        depth: u8,
    };

    pub fn init(allocator: std.mem.Allocator) SamplingProfiler {
        return .{
            .samples = std.ArrayList(Sample).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SamplingProfiler) void {
        self.samples.deinit(self.allocator);
    }

    pub fn sample(self: *SamplingProfiler) !void {
        var stack_trace: [32]usize = undefined;
        var stack_trace_iter = std.debug.StackIterator.init(@returnAddress(), null);
        var depth: u8 = 0;

        while (stack_trace_iter.next()) |addr| {
            if (depth >= stack_trace.len) break;
            stack_trace[depth] = addr;
            depth += 1;
        }

        try self.samples.append(self.allocator, .{
            .timestamp = std.time.microTimestamp(),
            .stack_trace = stack_trace,
            .depth = depth,
        });
    }

    pub fn exportFlameGraph(self: *SamplingProfiler) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit(self.allocator);
        const writer = buffer.writer(self.allocator);

        try writer.writeAll("# Flame Graph Data\n");
        try writer.print("# Total Samples: {}\n", .{self.samples.items.len});

        // This is simplified - real flame graph export would aggregate stack traces
        for (self.samples.items) |sample| {
            for (0..sample.depth) |i| {
                try writer.print("0x{x};", .{sample.stack_trace[i]});
            }
            try writer.writeAll(" 1\n");
        }

        return buffer.toOwnedSlice(self.allocator);
    }
};

/// Memory profiling
pub const MemoryProfiler = struct {
    allocations: std.atomic.Value(u64),
    deallocations: std.atomic.Value(u64),
    bytes_allocated: std.atomic.Value(u64),
    bytes_freed: std.atomic.Value(u64),
    peak_memory: std.atomic.Value(u64),

    pub fn init() MemoryProfiler {
        return .{
            .allocations = std.atomic.Value(u64).init(0),
            .deallocations = std.atomic.Value(u64).init(0),
            .bytes_allocated = std.atomic.Value(u64).init(0),
            .bytes_freed = std.atomic.Value(u64).init(0),
            .peak_memory = std.atomic.Value(u64).init(0),
        };
    }

    pub fn recordAlloc(self: *MemoryProfiler, size: u64) void {
        _ = self.allocations.fetchAdd(1, .monotonic);
        _ = self.bytes_allocated.fetchAdd(size, .monotonic);

        const current = self.bytes_allocated.load(.monotonic) - self.bytes_freed.load(.monotonic);
        var peak = self.peak_memory.load(.monotonic);

        while (current > peak) {
            if (self.peak_memory.cmpxchgWeak(peak, current, .monotonic, .monotonic)) |new_peak| {
                peak = new_peak;
            } else {
                break;
            }
        }
    }

    pub fn recordFree(self: *MemoryProfiler, size: u64) void {
        _ = self.deallocations.fetchAdd(1, .monotonic);
        _ = self.bytes_freed.fetchAdd(size, .monotonic);
    }

    pub fn getCurrentUsage(self: *MemoryProfiler) u64 {
        return self.bytes_allocated.load(.monotonic) - self.bytes_freed.load(.monotonic);
    }
};

// Tests
test "perf counter" {
    const counter = PerfCounter.start();

    // Do some work
    var sum: u64 = 0;
    for (0..1000) |i| {
        sum +%= i;
    }

    const cycles = counter.elapsed();
    try std.testing.expect(cycles > 0);
    try std.testing.expect(sum > 0); // Prevent optimization
}

test "trace span" {
    var span = TraceSpan.begin("test_operation", null);

    // Simulate work
    std.time.sleep(1 * std.time.ns_per_ms);

    const duration = span.end();
    try std.testing.expect(duration >= 1000); // At least 1ms in microseconds
}
