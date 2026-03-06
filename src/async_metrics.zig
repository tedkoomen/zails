/// Non-blocking asynchronous metrics export
/// Background thread for metrics collection without blocking request processing

const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const metrics = @import("metrics.zig");

/// Asynchronous metrics exporter
/// Runs in background thread to avoid blocking request handling
pub const AsyncMetricsExporter = struct {
    thread: Thread,
    shutdown: std.atomic.Value(bool),
    registry: *metrics.MetricsRegistry,
    export_interval_ns: u64,
    allocator: Allocator,
    runtime_controller: *@import("config_system.zig").RuntimeController,

    pub fn init(
        allocator: Allocator,
        registry: *metrics.MetricsRegistry,
        runtime_controller: *@import("config_system.zig").RuntimeController,
        export_interval_seconds: u64,
    ) !AsyncMetricsExporter {
        var exporter = AsyncMetricsExporter{
            .thread = undefined,
            .shutdown = std.atomic.Value(bool).init(false),
            .registry = registry,
            .export_interval_ns = export_interval_seconds * std.time.ns_per_s,
            .allocator = allocator,
            .runtime_controller = runtime_controller,
        };

        exporter.thread = try Thread.spawn(.{}, workerThread, .{&exporter});

        return exporter;
    }

    pub fn deinit(self: *AsyncMetricsExporter) void {
        self.shutdown.store(true, .release);
        self.thread.join();
    }

    fn workerThread(self: *AsyncMetricsExporter) void {
        std.log.info("Async metrics exporter started", .{});

        while (!self.shutdown.load(.acquire)) {
            // Sleep for export interval
            Thread.sleep(self.export_interval_ns);

            // Check if metrics are enabled
            if (!self.runtime_controller.isMetricsEnabled()) {
                continue;
            }

            // Export metrics (non-blocking - fire and forget)
            self.exportMetrics() catch |err| {
                std.log.err("Failed to export metrics: {}", .{err});
            };
        }

        std.log.info("Async metrics exporter stopped", .{});
    }

    fn exportMetrics(self: *AsyncMetricsExporter) !void {
        // Log summary
        self.registry.logMetrics();

        // Export to Prometheus (could write to file or push to gateway)
        // For now, we just log
        // In production, you'd write to a file or send via HTTP
    }
};

/// Non-blocking StatsD client using ring buffer
pub const AsyncStatsDClient = struct {
    thread: Thread,
    shutdown: std.atomic.Value(bool),
    buffer: RingBuffer,
    socket: std.net.Stream,
    allocator: Allocator,
    dropped_metrics: std.atomic.Value(u64),

    const RingBuffer = struct {
        items: []Metric,
        head: std.atomic.Value(usize),
        tail: std.atomic.Value(usize),
        capacity: usize,

        const Metric = struct {
            name: [128]u8,
            value: f64,
            metric_type: MetricType,
        };

        const MetricType = enum {
            counter,
            gauge,
            timing,
        };

        fn init(allocator: Allocator, capacity: usize) !RingBuffer {
            return RingBuffer{
                .items = try allocator.alloc(Metric, capacity),
                .head = std.atomic.Value(usize).init(0),
                .tail = std.atomic.Value(usize).init(0),
                .capacity = capacity,
            };
        }

        fn deinit(self: *RingBuffer, allocator: Allocator) void {
            allocator.free(self.items);
        }

        fn push(self: *RingBuffer, metric: Metric) bool {
            const head = self.head.load(.acquire);
            const next_head = (head + 1) % self.capacity;
            const tail = self.tail.load(.acquire);

            if (next_head == tail) {
                return false; // Buffer full
            }

            self.items[head] = metric;
            self.head.store(next_head, .release);
            return true;
        }

        fn pop(self: *RingBuffer) ?Metric {
            const tail = self.tail.load(.acquire);
            const head = self.head.load(.acquire);

            if (tail == head) {
                return null; // Buffer empty
            }

            const metric = self.items[tail];
            self.tail.store((tail + 1) % self.capacity, .release);
            return metric;
        }
    };

    pub fn init(allocator: Allocator, host: []const u8, port: u16) !AsyncStatsDClient {
        const address = try std.net.Address.parseIp(host, port);
        const socket = try std.net.tcpConnectToAddress(address);

        var client = AsyncStatsDClient{
            .thread = undefined,
            .shutdown = std.atomic.Value(bool).init(false),
            .buffer = try RingBuffer.init(allocator, 4096),
            .socket = socket,
            .allocator = allocator,
            .dropped_metrics = std.atomic.Value(u64).init(0),
        };

        client.thread = try Thread.spawn(.{}, senderThread, .{&client});

        return client;
    }

    pub fn deinit(self: *AsyncStatsDClient) void {
        self.shutdown.store(true, .release);
        self.thread.join();
        self.buffer.deinit(self.allocator);
        self.socket.close();
    }

    /// Non-blocking counter increment
    pub fn counter(self: *AsyncStatsDClient, name: []const u8, value: i64) void {
        var metric = RingBuffer.Metric{
            .name = undefined,
            .value = @floatFromInt(value),
            .metric_type = .counter,
        };

        const len = @min(name.len, metric.name.len - 1);
        @memcpy(metric.name[0..len], name[0..len]);
        metric.name[len] = 0;

        if (!self.buffer.push(metric)) {
            const dropped = self.dropped_metrics.fetchAdd(1, .monotonic);
            // Log every 1000 dropped metrics to avoid log spam
            if (dropped % 1000 == 0) {
                std.log.warn("StatsD buffer full - dropped {} total metrics", .{dropped + 1});
            }
        }
    }

    /// Non-blocking gauge
    pub fn gauge(self: *AsyncStatsDClient, name: []const u8, value: f64) void {
        var metric = RingBuffer.Metric{
            .name = undefined,
            .value = value,
            .metric_type = .gauge,
        };

        const len = @min(name.len, metric.name.len - 1);
        @memcpy(metric.name[0..len], name[0..len]);
        metric.name[len] = 0;

        if (!self.buffer.push(metric)) {
            const dropped = self.dropped_metrics.fetchAdd(1, .monotonic);
            if (dropped % 1000 == 0) {
                std.log.warn("StatsD buffer full - dropped {} total metrics", .{dropped + 1});
            }
        }
    }

    fn senderThread(self: *AsyncStatsDClient) void {
        std.log.info("Async StatsD client started", .{});

        var buf: [256]u8 = undefined;

        while (!self.shutdown.load(.acquire)) {
            if (self.buffer.pop()) |metric| {
                // Format and send metric
                const name_len = std.mem.indexOf(u8, &metric.name, "\x00") orelse metric.name.len;
                const name = metric.name[0..name_len];

                const msg = switch (metric.metric_type) {
                    .counter => std.fmt.bufPrint(&buf, "{s}:{d}|c\n", .{ name, @as(i64, @intFromFloat(metric.value)) }) catch continue,
                    .gauge => std.fmt.bufPrint(&buf, "{s}:{d}|g\n", .{ name, metric.value }) catch continue,
                    .timing => std.fmt.bufPrint(&buf, "{s}:{d}|ms\n", .{ name, @as(u64, @intFromFloat(metric.value)) }) catch continue,
                };

                self.socket.writeAll(msg) catch |err| {
                    std.log.err("Failed to send StatsD metric: {}", .{err});
                };
            } else {
                // No metrics, sleep briefly
                Thread.sleep(10 * std.time.ns_per_ms);
            }
        }

        std.log.info("Async StatsD client stopped", .{});
    }
};
