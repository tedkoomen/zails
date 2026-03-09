const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    ports: []u16,
    worker_threads: ?usize,
    enable_numa: bool,
    buffer_size: usize,
    pool_size: usize,
    max_connections: usize,
    verbose: bool,

    pub fn parseArgs(allocator: Allocator, args: []const []const u8) !Config {
        var ports = std.ArrayList(u16){};
        errdefer ports.deinit(allocator);

        var worker_threads: ?usize = null;
        var enable_numa: bool = true;
        var buffer_size: usize = 4096;
        var pool_size: usize = 1024;
        var max_connections: usize = 10000;
        var verbose: bool = false;

        var i: usize = 1; // Skip program name
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.eql(u8, arg, "--ports") or std.mem.eql(u8, arg, "-p")) {
                i += 1;
                if (i >= args.len) return error.MissingPortsValue;

                // Parse comma-separated ports: "8080,8081,8082"
                var port_iter = std.mem.splitScalar(u8, args[i], ',');
                while (port_iter.next()) |port_str| {
                    const port = try std.fmt.parseInt(u16, port_str, 10);
                    try ports.append(allocator, port);
                }
            } else if (std.mem.eql(u8, arg, "--workers") or std.mem.eql(u8, arg, "-w")) {
                i += 1;
                if (i >= args.len) return error.MissingWorkersValue;
                worker_threads = try std.fmt.parseInt(usize, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--numa")) {
                enable_numa = true;
            } else if (std.mem.eql(u8, arg, "--no-numa")) {
                enable_numa = false;
            } else if (std.mem.eql(u8, arg, "--buffer-size")) {
                i += 1;
                if (i >= args.len) return error.MissingBufferSizeValue;
                buffer_size = try std.fmt.parseInt(usize, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--pool-size")) {
                i += 1;
                if (i >= args.len) return error.MissingPoolSizeValue;
                pool_size = try std.fmt.parseInt(usize, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--max-connections")) {
                i += 1;
                if (i >= args.len) return error.MissingMaxConnectionsValue;
                max_connections = try std.fmt.parseInt(usize, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
                verbose = true;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                printUsage();
                return error.HelpRequested;
            } else {
                std.log.err("Unknown argument: {s}", .{arg});
                printUsage();
                return error.UnknownArgument;
            }
        }

        if (ports.items.len == 0) {
            std.log.err("No ports specified. Use --ports or -p", .{});
            printUsage();
            return error.NoPortsSpecified;
        }

        const ports_slice = try ports.toOwnedSlice(allocator);

        return Config{
            .ports = ports_slice,
            .worker_threads = worker_threads,
            .enable_numa = enable_numa,
            .buffer_size = buffer_size,
            .pool_size = pool_size,
            .max_connections = max_connections,
            .verbose = verbose,
        };
    }

    pub fn validate(self: Config) !void {
        if (self.ports.len == 0) {
            return error.NoPortsSpecified;
        }

        for (self.ports) |port| {
            if (port < 1024) {
                std.log.warn("Port {} requires root privileges", .{port});
            }
        }

        if (self.worker_threads) |workers| {
            if (workers == 0) {
                return error.InvalidWorkerCount;
            }
        }

        if (self.buffer_size == 0) {
            return error.InvalidBufferSize;
        }

        if (self.pool_size == 0) {
            return error.InvalidPoolSize;
        }
    }

    pub fn deinit(self: *Config, allocator: Allocator) void {
        allocator.free(self.ports);
    }

    fn printUsage() void {
        std.log.info(
            \\Usage: zig_server [OPTIONS]
            \\
            \\Options:
            \\  -p, --ports <ports>           Comma-separated list of ports (required)
            \\                                Example: --ports 8080,8081,8082
            \\  -w, --workers <count>         Number of worker threads (default: auto)
            \\  --numa                        Enable NUMA awareness (default)
            \\  --no-numa                     Disable NUMA awareness
            \\  --buffer-size <bytes>         Buffer size (default: 4096)
            \\  --pool-size <count>           Object pool size per worker (default: 1024)
            \\  --max-connections <count>     Maximum concurrent connections (default: 10000)
            \\  -v, --verbose                 Enable verbose startup banners
            \\  -h, --help                    Show this help message
            \\
            \\Examples:
            \\  zig_server --ports 8080,8081,8082 --workers 16 --numa
            \\  zig_server -p 8080 -w 4 --pool-size 2048 --max-connections 50000
            \\
        , .{});
    }
};

// Tests
test "parse config with NUMA" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "./server", "--ports", "8080,8081", "--numa" };

    var config = try Config.parseArgs(allocator, args);
    defer config.deinit(allocator);

    try std.testing.expectEqual(true, config.enable_numa);
    try std.testing.expectEqual(@as(usize, 2), config.ports.len);
    try std.testing.expectEqual(@as(u16, 8080), config.ports[0]);
    try std.testing.expectEqual(@as(u16, 8081), config.ports[1]);
    try std.testing.expectEqual(@as(usize, 1024), config.pool_size); // default
}

test "parse config without NUMA" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "./server", "--ports", "9000", "--no-numa", "--workers", "4" };

    var config = try Config.parseArgs(allocator, args);
    defer config.deinit(allocator);

    try std.testing.expectEqual(false, config.enable_numa);
    try std.testing.expectEqual(@as(usize, 1), config.ports.len);
    try std.testing.expectEqual(@as(?usize, 4), config.worker_threads);
    try std.testing.expectEqual(@as(usize, 1024), config.pool_size); // default
}

test "parse config with custom pool size" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "./server", "--ports", "8080", "--pool-size", "2048" };

    var config = try Config.parseArgs(allocator, args);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2048), config.pool_size);
}
