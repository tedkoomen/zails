/// Advanced configuration system for Zerver
/// Supports YAML/JSON config files with runtime reloading

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Zerver configuration (loaded from config/)
pub const ZerverConfig = struct {
    server: ServerConfig,
    metrics: MetricsConfig,
    persistence: PersistenceConfig,
    sla: SLAConfig,
    profiling: ProfilingConfig,
    feeds: FeedsConfig,

    pub const ServerConfig = struct {
        ports: []u16,
        worker_threads: ?usize,
        enable_numa: bool,
        pool_size: usize,
        max_connections: usize,
        read_timeout_ms: u64,
        write_timeout_ms: u64,
    };

    pub const MetricsConfig = struct {
        enabled: bool,
        export_interval_seconds: u64,
        prometheus: PrometheusConfig,
        statsd: StatsDConfig,

        pub const PrometheusConfig = struct {
            enabled: bool,
            port: u16,
            path: []const u8,
        };

        pub const StatsDConfig = struct {
            enabled: bool,
            host: []const u8,
            port: u16,
            prefix: []const u8,
        };
    };

    pub const PersistenceConfig = struct {
        enabled: bool,
        backend: BackendType,
        connection_string: []const u8,
        pool_size: usize,
        timeout_ms: u64,
        clickhouse: ClickHouseConfig,

        pub const BackendType = enum {
            none,
            redis,
            postgresql,
            sqlite,
            rocksdb,
            clickhouse,
        };

        pub const ClickHouseConfig = struct {
            enabled: bool,
            url: []const u8,
            database: []const u8,
            username: []const u8,
            password: []const u8,
            use_tls: bool,
            batch_size: usize,
            flush_interval_seconds: u64,
            buffer_capacity: usize,
            pool_size: usize,
            table_name: []const u8,
        };
    };

    pub const SLAConfig = struct {
        enabled: bool,
        targets: []SLATarget,

        pub const SLATarget = struct {
            name: []const u8,
            metric: []const u8,
            threshold: f64,
            window_seconds: u64,
            alert_channel: []const u8, // webhook, email, etc.
        };
    };

    pub const ProfilingConfig = struct {
        enabled: bool,
        cpu_profiling: bool,
        memory_profiling: bool,
        trace_sampling: bool,
        sampling_rate: f64, // 0.0 to 1.0
        export_flame_graphs: bool,
    };

    pub const FeedsConfig = struct {
        enabled: bool,
        feeds: []const FeedConfigEntry,

        pub const FeedConfigEntry = struct {
            name: []const u8,
            bind_address: []const u8,
            bind_port: u16,
            multicast_group: ?[]const u8,
            multicast_interface: ?[]const u8,
            protocol_id: u8,
            enabled: bool,
            recv_buffer_size: usize,
            publish_topic: []const u8,
            initial_sequence: u64,
        };
    };

    /// Load configuration from file
    /// ⚠️  NOT IMPLEMENTED - Use default() or build ZerverConfig manually ⚠️
    /// JSON and YAML parsing are stubbed out and will return error.NotImplemented
    pub fn loadFromFile(allocator: Allocator, path: []const u8) !ZerverConfig {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
        defer allocator.free(content);

        // Determine format from extension
        if (std.mem.endsWith(u8, path, ".json")) {
            return try parseJSON(allocator, content);
        } else if (std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) {
            return try parseYAML(allocator, content);
        } else {
            return error.UnknownConfigFormat;
        }
    }

    /// Parse JSON configuration
    /// TODO: Implement using std.json.parseFromSlice
    fn parseJSON(allocator: Allocator, content: []const u8) !ZerverConfig {
        _ = allocator;
        _ = content;
        std.log.err("JSON config parsing not implemented - use ZerverConfig.default() instead", .{});
        return error.NotImplemented;
    }

    /// Parse YAML configuration
    /// TODO: Implement using external YAML parser library
    fn parseYAML(allocator: Allocator, content: []const u8) !ZerverConfig {
        _ = allocator;
        _ = content;
        std.log.err("YAML config parsing not implemented - use ZerverConfig.default() instead", .{});
        return error.NotImplemented;
    }

    /// Generate default configuration
    pub fn default(allocator: Allocator) !ZerverConfig {
        const ports = try allocator.alloc(u16, 1);
        ports[0] = 8080;

        return ZerverConfig{
            .server = .{
                .ports = ports,
                .worker_threads = null, // Auto-detect
                .enable_numa = true,
                .pool_size = 1024,
                .max_connections = 10000,
                .read_timeout_ms = 30000,
                .write_timeout_ms = 30000,
            },
            .metrics = .{
                .enabled = true,
                .export_interval_seconds = 15,
                .prometheus = .{
                    .enabled = true,
                    .port = 9090,
                    .path = "/metrics",
                },
                .statsd = .{
                    .enabled = false,
                    .host = "localhost",
                    .port = 8125,
                    .prefix = "zerver",
                },
            },
            .persistence = .{
                .enabled = false,
                .backend = .none,
                .connection_string = "",
                .pool_size = 10,
                .timeout_ms = 5000,
                .clickhouse = .{
                    .enabled = false,
                    .url = "http://localhost:8123",
                    .database = "zerver",
                    .username = "default",
                    .password = "",
                    .use_tls = false,
                    .batch_size = 1000,
                    .flush_interval_seconds = 10,
                    .buffer_capacity = 10000,
                    .pool_size = 4,
                    .table_name = "zerver_request_metrics",
                },
            },
            .sla = .{
                .enabled = false,
                .targets = &[_]SLAConfig.SLATarget{},
            },
            .profiling = .{
                .enabled = false,
                .cpu_profiling = false,
                .memory_profiling = false,
                .trace_sampling = false,
                .sampling_rate = 0.01, // 1% sampling
                .export_flame_graphs = false,
            },
            .feeds = .{
                .enabled = false,
                .feeds = &[_]FeedsConfig.FeedConfigEntry{},
            },
        };
    }

    /// Export as YAML
    pub fn exportYAML(self: *const ZerverConfig, allocator: Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer(allocator);

        try writer.writeAll("# Zerver Configuration\n\n");

        // Server section
        try writer.writeAll("server:\n");
        try writer.print("  ports: [{d}]\n", .{self.server.ports[0]});
        if (self.server.worker_threads) |wt| {
            try writer.print("  worker_threads: {}\n", .{wt});
        } else {
            try writer.writeAll("  worker_threads: auto\n");
        }
        try writer.print("  enable_numa: {}\n", .{self.server.enable_numa});
        try writer.print("  pool_size: {}\n", .{self.server.pool_size});
        try writer.print("  max_connections: {}\n", .{self.server.max_connections});
        try writer.print("  read_timeout_ms: {}\n", .{self.server.read_timeout_ms});
        try writer.print("  write_timeout_ms: {}\n\n", .{self.server.write_timeout_ms});

        // Metrics section
        try writer.writeAll("metrics:\n");
        try writer.print("  enabled: {}\n", .{self.metrics.enabled});
        try writer.print("  export_interval_seconds: {}\n", .{self.metrics.export_interval_seconds});
        try writer.writeAll("  prometheus:\n");
        try writer.print("    enabled: {}\n", .{self.metrics.prometheus.enabled});
        try writer.print("    port: {}\n", .{self.metrics.prometheus.port});
        try writer.print("    path: {s}\n", .{self.metrics.prometheus.path});
        try writer.writeAll("  statsd:\n");
        try writer.print("    enabled: {}\n", .{self.metrics.statsd.enabled});
        try writer.print("    host: {s}\n", .{self.metrics.statsd.host});
        try writer.print("    port: {}\n", .{self.metrics.statsd.port});
        try writer.print("    prefix: {s}\n\n", .{self.metrics.statsd.prefix});

        // Persistence section
        try writer.writeAll("persistence:\n");
        try writer.print("  enabled: {}\n", .{self.persistence.enabled});
        try writer.print("  backend: {s}\n", .{@tagName(self.persistence.backend)});
        try writer.print("  connection_string: \"{s}\"\n", .{self.persistence.connection_string});
        try writer.print("  pool_size: {}\n", .{self.persistence.pool_size});
        try writer.print("  timeout_ms: {}\n\n", .{self.persistence.timeout_ms});

        // SLA section
        try writer.writeAll("sla:\n");
        try writer.print("  enabled: {}\n", .{self.sla.enabled});
        try writer.writeAll("  targets:\n");
        for (self.sla.targets) |target| {
            try writer.print("    - name: {s}\n", .{target.name});
            try writer.print("      metric: {s}\n", .{target.metric});
            try writer.print("      threshold: {d}\n", .{target.threshold});
            try writer.print("      window_seconds: {}\n", .{target.window_seconds});
            try writer.print("      alert_channel: {s}\n", .{target.alert_channel});
        }
        try writer.writeAll("\n");

        // Profiling section
        try writer.writeAll("profiling:\n");
        try writer.print("  enabled: {}\n", .{self.profiling.enabled});
        try writer.print("  cpu_profiling: {}\n", .{self.profiling.cpu_profiling});
        try writer.print("  memory_profiling: {}\n", .{self.profiling.memory_profiling});
        try writer.print("  trace_sampling: {}\n", .{self.profiling.trace_sampling});
        try writer.print("  sampling_rate: {d:.3}\n", .{self.profiling.sampling_rate});
        try writer.print("  export_flame_graphs: {}\n\n", .{self.profiling.export_flame_graphs});

        // Feeds section
        try writer.writeAll("feeds:\n");
        try writer.print("  enabled: {}\n", .{self.feeds.enabled});
        try writer.writeAll("  feeds:\n");
        for (self.feeds.feeds) |feed| {
            try writer.print("    - name: {s}\n", .{feed.name});
            try writer.print("      bind_address: {s}\n", .{feed.bind_address});
            try writer.print("      bind_port: {}\n", .{feed.bind_port});
            if (feed.multicast_group) |group| {
                try writer.print("      multicast_group: {s}\n", .{group});
            }
            try writer.print("      protocol_id: {}\n", .{feed.protocol_id});
            try writer.print("      enabled: {}\n", .{feed.enabled});
            try writer.print("      recv_buffer_size: {}\n", .{feed.recv_buffer_size});
            try writer.print("      publish_topic: {s}\n", .{feed.publish_topic});
        }

        return buffer.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *ZerverConfig, allocator: Allocator) void {
        allocator.free(self.server.ports);
        // Free other allocated fields as needed
    }
};

/// Runtime configuration controller
/// Allows enabling/disabling features at runtime without restart
pub const RuntimeController = struct {
    metrics_enabled: std.atomic.Value(bool),
    profiling_enabled: std.atomic.Value(bool),
    cpu_profiling_enabled: std.atomic.Value(bool),
    memory_profiling_enabled: std.atomic.Value(bool),
    trace_sampling_enabled: std.atomic.Value(bool),

    pub fn init(config: *const ZerverConfig) RuntimeController {
        return .{
            .metrics_enabled = std.atomic.Value(bool).init(config.metrics.enabled),
            .profiling_enabled = std.atomic.Value(bool).init(config.profiling.enabled),
            .cpu_profiling_enabled = std.atomic.Value(bool).init(config.profiling.cpu_profiling),
            .memory_profiling_enabled = std.atomic.Value(bool).init(config.profiling.memory_profiling),
            .trace_sampling_enabled = std.atomic.Value(bool).init(config.profiling.trace_sampling),
        };
    }

    // Runtime toggles
    pub fn enableMetrics(self: *RuntimeController) void {
        self.metrics_enabled.store(true, .release);
        std.log.info("Metrics enabled at runtime", .{});
    }

    pub fn disableMetrics(self: *RuntimeController) void {
        self.metrics_enabled.store(false, .release);
        std.log.info("Metrics disabled at runtime", .{});
    }

    pub fn enableProfiling(self: *RuntimeController) void {
        self.profiling_enabled.store(true, .release);
        std.log.info("Profiling enabled at runtime", .{});
    }

    pub fn disableProfiling(self: *RuntimeController) void {
        self.profiling_enabled.store(false, .release);
        self.cpu_profiling_enabled.store(false, .release);
        self.memory_profiling_enabled.store(false, .release);
        self.trace_sampling_enabled.store(false, .release);
        std.log.info("Profiling disabled at runtime", .{});
    }

    pub fn isMetricsEnabled(self: *RuntimeController) bool {
        return self.metrics_enabled.load(.acquire);
    }

    pub fn isProfilingEnabled(self: *RuntimeController) bool {
        return self.profiling_enabled.load(.acquire);
    }

    pub fn isCpuProfilingEnabled(self: *RuntimeController) bool {
        return self.profiling_enabled.load(.acquire) and
            self.cpu_profiling_enabled.load(.acquire);
    }
};
