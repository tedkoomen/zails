/// Advanced configuration system for Zails
/// Supports YAML/JSON config files with runtime reloading
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Zails configuration (loaded from config/)
pub const ZailsConfig = struct {
    server: ServerConfig,
    metrics: MetricsConfig,
    persistence: PersistenceConfig,
    sla: SLAConfig,
    profiling: ProfilingConfig,
    feeds: FeedsConfig,
    owned_strings: []const []const u8 = &[_][]const u8{},

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
    /// JSON is supported via std.json. YAML returns error.UnsupportedConfigFormat
    /// unless a YAML parser is added to the project.
    pub fn loadFromFile(allocator: Allocator, path: []const u8) !ZailsConfig {
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

    fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.Value {
        return object.get(name);
    }

    fn boolField(object: std.json.ObjectMap, name: []const u8, current: bool) !bool {
        const value = objectField(object, name) orelse return current;
        return switch (value) {
            .bool => |b| b,
            else => error.InvalidConfigValue,
        };
    }

    fn usizeField(object: std.json.ObjectMap, name: []const u8, current: usize) !usize {
        const value = objectField(object, name) orelse return current;
        return switch (value) {
            .integer => |i| if (i < 0 or i > std.math.maxInt(usize)) error.InvalidConfigValue else @as(usize, @intCast(i)),
            else => error.InvalidConfigValue,
        };
    }

    fn u64Field(object: std.json.ObjectMap, name: []const u8, current: u64) !u64 {
        const value = objectField(object, name) orelse return current;
        return switch (value) {
            .integer => |i| if (i < 0) error.InvalidConfigValue else @as(u64, @intCast(i)),
            else => error.InvalidConfigValue,
        };
    }

    fn u16Field(object: std.json.ObjectMap, name: []const u8, current: u16) !u16 {
        const value = try u64Field(object, name, current);
        if (value > std.math.maxInt(u16)) return error.InvalidConfigValue;
        return @intCast(value);
    }

    fn f64Field(object: std.json.ObjectMap, name: []const u8, current: f64) !f64 {
        const value = objectField(object, name) orelse return current;
        return switch (value) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => error.InvalidConfigValue,
        };
    }

    fn ownedStringField(
        allocator: Allocator,
        owned_strings: *std.ArrayList([]const u8),
        object: std.json.ObjectMap,
        name: []const u8,
        current: []const u8,
    ) ![]const u8 {
        const value = objectField(object, name) orelse return current;
        if (value != .string) return error.InvalidConfigValue;
        const copy = try allocator.dupe(u8, value.string);
        errdefer allocator.free(copy);
        try owned_strings.append(allocator, copy);
        return copy;
    }

    fn parsePorts(allocator: Allocator, value: std.json.Value) ![]u16 {
        if (value != .array) return error.InvalidConfigValue;
        if (value.array.items.len == 0) return error.InvalidConfigValue;

        var ports = std.ArrayList(u16){};
        errdefer ports.deinit(allocator);

        for (value.array.items) |item| {
            if (item != .integer or item.integer < 0 or item.integer > std.math.maxInt(u16)) {
                return error.InvalidConfigValue;
            }
            try ports.append(allocator, @intCast(item.integer));
        }

        return ports.toOwnedSlice(allocator);
    }

    /// Parse JSON configuration
    fn parseJSON(allocator: Allocator, content: []const u8) !ZailsConfig {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidConfigValue;
        const root = parsed.value.object;

        var config = try ZailsConfig.default(allocator);
        errdefer config.deinit(allocator);

        var owned_strings = std.ArrayList([]const u8){};
        errdefer {
            for (owned_strings.items) |s| allocator.free(s);
            owned_strings.deinit(allocator);
        }

        if (objectField(root, "server")) |server_value| {
            if (server_value != .object) return error.InvalidConfigValue;
            const server = server_value.object;

            if (objectField(server, "ports")) |ports_value| {
                const new_ports = try parsePorts(allocator, ports_value);
                allocator.free(config.server.ports);
                config.server.ports = new_ports;
            }

            if (objectField(server, "worker_threads")) |worker_value| {
                config.server.worker_threads = switch (worker_value) {
                    .integer => |i| if (i < 0 or i > std.math.maxInt(usize)) return error.InvalidConfigValue else @as(usize, @intCast(i)),
                    .string => |s| if (std.mem.eql(u8, s, "auto")) null else return error.InvalidConfigValue,
                    .null => null,
                    else => return error.InvalidConfigValue,
                };
            }

            config.server.enable_numa = try boolField(server, "enable_numa", config.server.enable_numa);
            config.server.pool_size = try usizeField(server, "pool_size", config.server.pool_size);
            config.server.max_connections = try usizeField(server, "max_connections", config.server.max_connections);
            config.server.read_timeout_ms = try u64Field(server, "read_timeout_ms", config.server.read_timeout_ms);
            config.server.write_timeout_ms = try u64Field(server, "write_timeout_ms", config.server.write_timeout_ms);
        }

        if (objectField(root, "metrics")) |metrics_value| {
            if (metrics_value != .object) return error.InvalidConfigValue;
            const metrics_obj = metrics_value.object;
            config.metrics.enabled = try boolField(metrics_obj, "enabled", config.metrics.enabled);
            config.metrics.export_interval_seconds = try u64Field(metrics_obj, "export_interval_seconds", config.metrics.export_interval_seconds);

            if (objectField(metrics_obj, "prometheus")) |prom_value| {
                if (prom_value != .object) return error.InvalidConfigValue;
                const prom = prom_value.object;
                config.metrics.prometheus.enabled = try boolField(prom, "enabled", config.metrics.prometheus.enabled);
                config.metrics.prometheus.port = try u16Field(prom, "port", config.metrics.prometheus.port);
                config.metrics.prometheus.path = try ownedStringField(allocator, &owned_strings, prom, "path", config.metrics.prometheus.path);
            }

            if (objectField(metrics_obj, "statsd")) |statsd_value| {
                if (statsd_value != .object) return error.InvalidConfigValue;
                const statsd = statsd_value.object;
                config.metrics.statsd.enabled = try boolField(statsd, "enabled", config.metrics.statsd.enabled);
                config.metrics.statsd.host = try ownedStringField(allocator, &owned_strings, statsd, "host", config.metrics.statsd.host);
                config.metrics.statsd.port = try u16Field(statsd, "port", config.metrics.statsd.port);
                config.metrics.statsd.prefix = try ownedStringField(allocator, &owned_strings, statsd, "prefix", config.metrics.statsd.prefix);
            }
        }

        if (objectField(root, "persistence")) |persistence_value| {
            if (persistence_value != .object) return error.InvalidConfigValue;
            const persistence = persistence_value.object;
            config.persistence.enabled = try boolField(persistence, "enabled", config.persistence.enabled);
            config.persistence.connection_string = try ownedStringField(allocator, &owned_strings, persistence, "connection_string", config.persistence.connection_string);
            config.persistence.pool_size = try usizeField(persistence, "pool_size", config.persistence.pool_size);
            config.persistence.timeout_ms = try u64Field(persistence, "timeout_ms", config.persistence.timeout_ms);

            if (objectField(persistence, "backend")) |backend_value| {
                if (backend_value != .string) return error.InvalidConfigValue;
                config.persistence.backend = std.meta.stringToEnum(PersistenceConfig.BackendType, backend_value.string) orelse return error.InvalidConfigValue;
            }

            if (objectField(persistence, "clickhouse")) |clickhouse_value| {
                if (clickhouse_value != .object) return error.InvalidConfigValue;
                const clickhouse = clickhouse_value.object;
                config.persistence.clickhouse.enabled = try boolField(clickhouse, "enabled", config.persistence.clickhouse.enabled);
                config.persistence.clickhouse.url = try ownedStringField(allocator, &owned_strings, clickhouse, "url", config.persistence.clickhouse.url);
                config.persistence.clickhouse.database = try ownedStringField(allocator, &owned_strings, clickhouse, "database", config.persistence.clickhouse.database);
                config.persistence.clickhouse.username = try ownedStringField(allocator, &owned_strings, clickhouse, "username", config.persistence.clickhouse.username);
                config.persistence.clickhouse.password = try ownedStringField(allocator, &owned_strings, clickhouse, "password", config.persistence.clickhouse.password);
                config.persistence.clickhouse.use_tls = try boolField(clickhouse, "use_tls", config.persistence.clickhouse.use_tls);
                config.persistence.clickhouse.batch_size = try usizeField(clickhouse, "batch_size", config.persistence.clickhouse.batch_size);
                config.persistence.clickhouse.flush_interval_seconds = try u64Field(clickhouse, "flush_interval_seconds", config.persistence.clickhouse.flush_interval_seconds);
                config.persistence.clickhouse.buffer_capacity = try usizeField(clickhouse, "buffer_capacity", config.persistence.clickhouse.buffer_capacity);
                config.persistence.clickhouse.pool_size = try usizeField(clickhouse, "pool_size", config.persistence.clickhouse.pool_size);
                config.persistence.clickhouse.table_name = try ownedStringField(allocator, &owned_strings, clickhouse, "table_name", config.persistence.clickhouse.table_name);
            }
        }

        if (objectField(root, "profiling")) |profiling_value| {
            if (profiling_value != .object) return error.InvalidConfigValue;
            const profiling = profiling_value.object;
            config.profiling.enabled = try boolField(profiling, "enabled", config.profiling.enabled);
            config.profiling.cpu_profiling = try boolField(profiling, "cpu_profiling", config.profiling.cpu_profiling);
            config.profiling.memory_profiling = try boolField(profiling, "memory_profiling", config.profiling.memory_profiling);
            config.profiling.trace_sampling = try boolField(profiling, "trace_sampling", config.profiling.trace_sampling);
            config.profiling.sampling_rate = try f64Field(profiling, "sampling_rate", config.profiling.sampling_rate);
            config.profiling.export_flame_graphs = try boolField(profiling, "export_flame_graphs", config.profiling.export_flame_graphs);
        }

        if (objectField(root, "feeds")) |feeds_value| {
            if (feeds_value != .object) return error.InvalidConfigValue;
            config.feeds.enabled = try boolField(feeds_value.object, "enabled", config.feeds.enabled);
        }

        config.owned_strings = try owned_strings.toOwnedSlice(allocator);
        return config;
    }

    /// Parse YAML configuration
    fn parseYAML(allocator: Allocator, content: []const u8) !ZailsConfig {
        _ = allocator;
        _ = content;
        std.log.err("YAML config parsing requires a YAML parser dependency; use JSON config for now", .{});
        return error.UnsupportedConfigFormat;
    }

    /// Generate default configuration
    pub fn default(allocator: Allocator) !ZailsConfig {
        const ports = try allocator.alloc(u16, 1);
        ports[0] = 8080;

        return ZailsConfig{
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
                    .prefix = "zails",
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
                    .database = "zails",
                    .username = "default",
                    .password = "",
                    .use_tls = false,
                    .batch_size = 1000,
                    .flush_interval_seconds = 10,
                    .buffer_capacity = 10000,
                    .pool_size = 4,
                    .table_name = "zails_request_metrics",
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
            .owned_strings = &[_][]const u8{},
        };
    }

    /// Export as YAML
    pub fn exportYAML(self: *const ZailsConfig, allocator: Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer(allocator);

        try writer.writeAll("# Zails Configuration\n\n");

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

    pub fn deinit(self: *ZailsConfig, allocator: Allocator) void {
        allocator.free(self.server.ports);
        for (self.owned_strings) |s| {
            allocator.free(s);
        }
        if (self.owned_strings.len > 0) {
            allocator.free(self.owned_strings);
        }
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

    pub fn init(config: *const ZailsConfig) RuntimeController {
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

test "parse JSON config overrides core fields" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "server": {
        \\    "ports": [9000, 9001],
        \\    "worker_threads": 8,
        \\    "enable_numa": false,
        \\    "max_connections": 1234
        \\  },
        \\  "metrics": {
        \\    "enabled": false,
        \\    "prometheus": { "path": "/internal/metrics" }
        \\  },
        \\  "persistence": {
        \\    "backend": "clickhouse",
        \\    "clickhouse": { "enabled": true, "database": "testdb" }
        \\  }
        \\}
    ;
    var config = try ZailsConfig.parseJSON(allocator, json);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), config.server.ports.len);
    try std.testing.expectEqual(@as(u16, 9000), config.server.ports[0]);
    try std.testing.expectEqual(@as(?usize, 8), config.server.worker_threads);
    try std.testing.expectEqual(false, config.server.enable_numa);
    try std.testing.expectEqual(@as(usize, 1234), config.server.max_connections);
    try std.testing.expectEqual(false, config.metrics.enabled);
    try std.testing.expectEqualStrings("/internal/metrics", config.metrics.prometheus.path);
    try std.testing.expectEqual(.clickhouse, config.persistence.backend);
    try std.testing.expectEqual(true, config.persistence.clickhouse.enabled);
    try std.testing.expectEqualStrings("testdb", config.persistence.clickhouse.database);
}
