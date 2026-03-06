/// Metrics collection for Zails
/// Lock-free atomic counters with Prometheus exposition format
/// Zero allocations in hot path

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Global metrics registry
pub const MetricsRegistry = struct {
    // Request metrics
    total_requests: std.atomic.Value(u64),
    successful_requests: std.atomic.Value(u64),
    failed_requests: std.atomic.Value(u64),

    // Latency tracking (microseconds)
    total_latency_us: std.atomic.Value(u64),
    min_latency_us: std.atomic.Value(u64),
    max_latency_us: std.atomic.Value(u64),

    // Connection metrics
    active_connections: std.atomic.Value(u64),
    total_connections: std.atomic.Value(u64),

    // Pool metrics
    pool_acquisitions: std.atomic.Value(u64),
    pool_exhaustions: std.atomic.Value(u64),

    // Worker metrics
    worker_busy_count: std.atomic.Value(u64),
    worker_idle_count: std.atomic.Value(u64),

    // Per-handler metrics (max 256 message types)
    handler_requests: [256]std.atomic.Value(u64),
    handler_errors: [256]std.atomic.Value(u64),

    // System metrics
    start_time_ms: i64,

    pub fn init() MetricsRegistry {
        var registry = MetricsRegistry{
            .total_requests = std.atomic.Value(u64).init(0),
            .successful_requests = std.atomic.Value(u64).init(0),
            .failed_requests = std.atomic.Value(u64).init(0),
            .total_latency_us = std.atomic.Value(u64).init(0),
            .min_latency_us = std.atomic.Value(u64).init(std.math.maxInt(u64)),
            .max_latency_us = std.atomic.Value(u64).init(0),
            .active_connections = std.atomic.Value(u64).init(0),
            .total_connections = std.atomic.Value(u64).init(0),
            .pool_acquisitions = std.atomic.Value(u64).init(0),
            .pool_exhaustions = std.atomic.Value(u64).init(0),
            .worker_busy_count = std.atomic.Value(u64).init(0),
            .worker_idle_count = std.atomic.Value(u64).init(0),
            .handler_requests = undefined,
            .handler_errors = undefined,
            .start_time_ms = std.time.milliTimestamp(),
        };

        // Initialize per-handler counters
        for (&registry.handler_requests) |*counter| {
            counter.* = std.atomic.Value(u64).init(0);
        }
        for (&registry.handler_errors) |*counter| {
            counter.* = std.atomic.Value(u64).init(0);
        }

        return registry;
    }

    /// Record a successful request
    pub fn recordRequest(self: *MetricsRegistry, msg_type: u8, latency_us: u64) void {
        _ = self.total_requests.fetchAdd(1, .monotonic);
        _ = self.successful_requests.fetchAdd(1, .monotonic);
        _ = self.total_latency_us.fetchAdd(latency_us, .monotonic);
        _ = self.handler_requests[msg_type].fetchAdd(1, .monotonic);

        // Update min latency
        var current_min = self.min_latency_us.load(.monotonic);
        while (latency_us < current_min) {
            if (self.min_latency_us.cmpxchgWeak(
                current_min,
                latency_us,
                .monotonic,
                .monotonic,
            )) |new_min| {
                current_min = new_min;
            } else {
                break;
            }
        }

        // Update max latency
        var current_max = self.max_latency_us.load(.monotonic);
        while (latency_us > current_max) {
            if (self.max_latency_us.cmpxchgWeak(
                current_max,
                latency_us,
                .monotonic,
                .monotonic,
            )) |new_max| {
                current_max = new_max;
            } else {
                break;
            }
        }
    }

    /// Record a failed request
    pub fn recordError(self: *MetricsRegistry, msg_type: u8) void {
        _ = self.total_requests.fetchAdd(1, .monotonic);
        _ = self.failed_requests.fetchAdd(1, .monotonic);
        _ = self.handler_errors[msg_type].fetchAdd(1, .monotonic);
    }

    /// Record connection accepted
    pub fn recordConnection(self: *MetricsRegistry) void {
        _ = self.total_connections.fetchAdd(1, .monotonic);
        _ = self.active_connections.fetchAdd(1, .monotonic);
    }

    /// Record connection closed
    pub fn recordConnectionClosed(self: *MetricsRegistry) void {
        _ = self.active_connections.fetchSub(1, .monotonic);
    }

    /// Record pool acquisition
    pub fn recordPoolAcquisition(self: *MetricsRegistry) void {
        _ = self.pool_acquisitions.fetchAdd(1, .monotonic);
    }

    /// Record pool exhaustion
    pub fn recordPoolExhaustion(self: *MetricsRegistry) void {
        _ = self.pool_exhaustions.fetchAdd(1, .monotonic);
    }

    /// Record worker state change
    pub fn recordWorkerBusy(self: *MetricsRegistry) void {
        _ = self.worker_busy_count.fetchAdd(1, .monotonic);
    }

    pub fn recordWorkerIdle(self: *MetricsRegistry) void {
        _ = self.worker_idle_count.fetchAdd(1, .monotonic);
    }

    /// Get average latency in microseconds
    pub fn getAverageLatencyUs(self: *MetricsRegistry) f64 {
        const total = self.total_latency_us.load(.monotonic);
        const count = self.successful_requests.load(.monotonic);
        if (count == 0) return 0.0;
        return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(count));
    }

    /// Get min latency, returning 0 if no requests have been recorded
    pub fn getMinLatencyUs(self: *MetricsRegistry) u64 {
        const min = self.min_latency_us.load(.monotonic);
        if (min == std.math.maxInt(u64)) return 0;
        return min;
    }

    /// Get uptime in seconds
    pub fn getUptimeSeconds(self: *MetricsRegistry) i64 {
        return @divTrunc(std.time.milliTimestamp() - self.start_time_ms, 1000);
    }

    /// Export metrics in Prometheus format
    pub fn exportPrometheus(self: *MetricsRegistry, allocator: Allocator) ![]const u8 {
        // Use ArenaAllocator to ensure all-or-nothing allocation
        // This prevents partial metric export on allocation failure
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var buffer = std.ArrayList(u8){};
        // Pre-allocate reasonable size to avoid many reallocations
        try buffer.ensureTotalCapacity(arena_allocator, 8192);
        const writer = buffer.writer(arena_allocator);

        // HELP and TYPE directives
        try writer.writeAll("# HELP zails_requests_total Total number of requests\n");
        try writer.writeAll("# TYPE zails_requests_total counter\n");
        try writer.print("zails_requests_total {}\n", .{self.total_requests.load(.monotonic)});

        try writer.writeAll("# HELP zails_requests_successful Successful requests\n");
        try writer.writeAll("# TYPE zails_requests_successful counter\n");
        try writer.print("zails_requests_successful {}\n", .{self.successful_requests.load(.monotonic)});

        try writer.writeAll("# HELP zails_requests_failed Failed requests\n");
        try writer.writeAll("# TYPE zails_requests_failed counter\n");
        try writer.print("zails_requests_failed {}\n", .{self.failed_requests.load(.monotonic)});

        try writer.writeAll("# HELP zails_latency_average_microseconds Average request latency\n");
        try writer.writeAll("# TYPE zails_latency_average_microseconds gauge\n");
        try writer.print("zails_latency_average_microseconds {d:.2}\n", .{self.getAverageLatencyUs()});

        try writer.writeAll("# HELP zails_latency_min_microseconds Minimum request latency\n");
        try writer.writeAll("# TYPE zails_latency_min_microseconds gauge\n");
        try writer.print("zails_latency_min_microseconds {}\n", .{self.getMinLatencyUs()});

        try writer.writeAll("# HELP zails_latency_max_microseconds Maximum request latency\n");
        try writer.writeAll("# TYPE zails_latency_max_microseconds gauge\n");
        try writer.print("zails_latency_max_microseconds {}\n", .{self.max_latency_us.load(.monotonic)});

        try writer.writeAll("# HELP zails_connections_active Active connections\n");
        try writer.writeAll("# TYPE zails_connections_active gauge\n");
        try writer.print("zails_connections_active {}\n", .{self.active_connections.load(.monotonic)});

        try writer.writeAll("# HELP zails_connections_total Total connections\n");
        try writer.writeAll("# TYPE zails_connections_total counter\n");
        try writer.print("zails_connections_total {}\n", .{self.total_connections.load(.monotonic)});

        try writer.writeAll("# HELP zails_pool_acquisitions Object pool acquisitions\n");
        try writer.writeAll("# TYPE zails_pool_acquisitions counter\n");
        try writer.print("zails_pool_acquisitions {}\n", .{self.pool_acquisitions.load(.monotonic)});

        try writer.writeAll("# HELP zails_pool_exhaustions Object pool exhaustions\n");
        try writer.writeAll("# TYPE zails_pool_exhaustions counter\n");
        try writer.print("zails_pool_exhaustions {}\n", .{self.pool_exhaustions.load(.monotonic)});

        try writer.writeAll("# HELP zails_uptime_seconds Server uptime\n");
        try writer.writeAll("# TYPE zails_uptime_seconds gauge\n");
        try writer.print("zails_uptime_seconds {}\n", .{self.getUptimeSeconds()});

        // Per-handler metrics
        try writer.writeAll("# HELP zails_handler_requests_total Requests per handler\n");
        try writer.writeAll("# TYPE zails_handler_requests_total counter\n");
        for (&self.handler_requests, 0..) |*counter, msg_type| {
            const count = counter.load(.monotonic);
            if (count > 0) {
                try writer.print("zails_handler_requests_total{{msg_type=\"{}\"}} {}\n", .{ msg_type, count });
            }
        }

        try writer.writeAll("# HELP zails_handler_errors_total Errors per handler\n");
        try writer.writeAll("# TYPE zails_handler_errors_total counter\n");
        for (&self.handler_errors, 0..) |*counter, msg_type| {
            const count = counter.load(.monotonic);
            if (count > 0) {
                try writer.print("zails_handler_errors_total{{msg_type=\"{}\"}} {}\n", .{ msg_type, count });
            }
        }

        // Duplicate to caller's allocator before arena is freed
        return allocator.dupe(u8, buffer.items);
    }

    /// Export metrics as JSON
    pub fn exportJSON(self: *MetricsRegistry, allocator: Allocator) ![]const u8 {
        // Use ArenaAllocator for consistent allocation behavior
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var buffer = std.ArrayList(u8){};
        try buffer.ensureTotalCapacity(arena_allocator, 8192);
        const writer = buffer.writer(arena_allocator);

        try writer.writeAll("{\n");
        try writer.print("  \"total_requests\": {},\n", .{self.total_requests.load(.monotonic)});
        try writer.print("  \"successful_requests\": {},\n", .{self.successful_requests.load(.monotonic)});
        try writer.print("  \"failed_requests\": {},\n", .{self.failed_requests.load(.monotonic)});
        try writer.print("  \"average_latency_us\": {d:.2},\n", .{self.getAverageLatencyUs()});
        try writer.print("  \"min_latency_us\": {},\n", .{self.getMinLatencyUs()});
        try writer.print("  \"max_latency_us\": {},\n", .{self.max_latency_us.load(.monotonic)});
        try writer.print("  \"active_connections\": {},\n", .{self.active_connections.load(.monotonic)});
        try writer.print("  \"total_connections\": {},\n", .{self.total_connections.load(.monotonic)});
        try writer.print("  \"pool_acquisitions\": {},\n", .{self.pool_acquisitions.load(.monotonic)});
        try writer.print("  \"pool_exhaustions\": {},\n", .{self.pool_exhaustions.load(.monotonic)});
        try writer.print("  \"uptime_seconds\": {},\n", .{self.getUptimeSeconds()});

        // Handler metrics
        try writer.writeAll("  \"handlers\": {\n");
        var first = true;
        for (&self.handler_requests, 0..) |*counter, msg_type| {
            const count = counter.load(.monotonic);
            if (count > 0) {
                if (!first) try writer.writeAll(",\n");
                try writer.print("    \"{}\": {{\n", .{msg_type});
                try writer.print("      \"requests\": {},\n", .{count});
                try writer.print("      \"errors\": {}\n", .{self.handler_errors[msg_type].load(.monotonic)});
                try writer.writeAll("    }");
                first = false;
            }
        }
        try writer.writeAll("\n  }\n");
        try writer.writeAll("}\n");

        // Duplicate to caller's allocator before arena is freed
        return allocator.dupe(u8, buffer.items);
    }

    /// Print metrics to log
    pub fn logMetrics(self: *MetricsRegistry) void {
        const total = self.total_requests.load(.monotonic);
        const success = self.successful_requests.load(.monotonic);
        const failed = self.failed_requests.load(.monotonic);
        const avg_latency = self.getAverageLatencyUs();
        const active_conns = self.active_connections.load(.monotonic);

        std.log.info("=== Metrics Summary ===", .{});
        std.log.info("Requests: {} total, {} success, {} failed", .{ total, success, failed });
        std.log.info("Latency: {d:.1}µs avg, {}µs min, {}µs max", .{
            avg_latency,
            self.getMinLatencyUs(),
            self.max_latency_us.load(.monotonic),
        });
        std.log.info("Connections: {} active, {} total", .{
            active_conns,
            self.total_connections.load(.monotonic),
        });
        std.log.info("Uptime: {}s", .{self.getUptimeSeconds()});
    }
};

/// StatsD client for sending metrics over UDP
pub const StatsDClient = struct {
    fd: std.posix.fd_t,
    address: std.net.Address,

    pub fn init(host: []const u8, port: u16) !StatsDClient {
        const address = try std.net.Address.parseIp(host, port);
        // StatsD uses UDP, not TCP
        const fd = try std.posix.socket(
            address.any.family,
            std.posix.SOCK.DGRAM,
            0,
        );

        return StatsDClient{
            .fd = fd,
            .address = address,
        };
    }

    pub fn deinit(self: *StatsDClient) void {
        std.posix.close(self.fd);
    }

    /// Send a UDP datagram to the StatsD server
    fn send(self: *StatsDClient, msg: []const u8) !void {
        _ = try std.posix.sendto(
            self.fd,
            msg,
            0,
            &self.address.any,
            self.address.getOsSockLen(),
        );
    }

    /// Send counter metric
    pub fn counter(self: *StatsDClient, name: []const u8, value: i64) !void {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{s}:{}|c\n", .{ name, value });
        try self.send(msg);
    }

    /// Send gauge metric
    pub fn gauge(self: *StatsDClient, name: []const u8, value: f64) !void {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{s}:{d}|g\n", .{ name, value });
        try self.send(msg);
    }

    /// Send timing metric (milliseconds)
    pub fn timing(self: *StatsDClient, name: []const u8, ms: u64) !void {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{s}:{}|ms\n", .{ name, ms });
        try self.send(msg);
    }
};

// Tests
test "metrics registry basic operations" {
    var registry = MetricsRegistry.init();

    // Record some requests
    registry.recordRequest(1, 100);
    registry.recordRequest(1, 200);
    registry.recordRequest(2, 150);

    try std.testing.expectEqual(@as(u64, 3), registry.total_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 3), registry.successful_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), registry.handler_requests[1].load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), registry.handler_requests[2].load(.monotonic));

    const avg = registry.getAverageLatencyUs();
    try std.testing.expect(avg > 145.0 and avg < 155.0); // ~150
}

test "metrics export prometheus format" {
    var registry = MetricsRegistry.init();
    registry.recordRequest(1, 100);
    registry.recordRequest(2, 200);

    const allocator = std.testing.allocator;
    const output = try registry.exportPrometheus(allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "zails_requests_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zails_latency_average_microseconds") != null);
}
