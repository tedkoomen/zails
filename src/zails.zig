/// Zails CLI - Convention-based server framework
/// Commands:
///   zails init <project_name>  - Create a new Zails project
///   zails build                - Build the current project

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;

const EmbeddedFile = struct { name: []const u8, content: []const u8 };

const embedded_server_files = [_]EmbeddedFile{
    .{ .name = "config.zig", .content = @embedFile("config.zig") },
    .{ .name = "numa.zig", .content = @embedFile("numa.zig") },
    .{ .name = "signals.zig", .content = @embedFile("signals.zig") },
    .{ .name = "proto.zig", .content = @embedFile("proto.zig") },
    .{ .name = "pool_lockfree.zig", .content = @embedFile("pool_lockfree.zig") },
    .{ .name = "handler_registry.zig", .content = @embedFile("handler_registry.zig") },
    .{ .name = "server_framework.zig", .content = @embedFile("server_framework.zig") },
    .{ .name = "client.zig", .content = @embedFile("client.zig") },
    .{ .name = "tls_openssl.zig", .content = @embedFile("tls_openssl.zig") },
    .{ .name = "result.zig", .content = @embedFile("result.zig") },
};

const Command = enum {
    init,
    build,
    create,
    scaffold,
    help,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printHelp();
        return;
    }

    const cmd = std.meta.stringToEnum(Command, args[1]) orelse {
        std.log.err("Unknown command: {s}", .{args[1]});
        printHelp();
        return error.UnknownCommand;
    };

    switch (cmd) {
        .init => {
            if (args.len < 3) {
                std.log.err("Usage: zails init <project_name>", .{});
                return error.MissingProjectName;
            }
            try initProject(args[2]);
        },
        .build => {
            try buildProject();
        },
        .create => {
            if (args.len < 3) {
                std.log.err("Usage: zails create <config|migration|handler|model|service>", .{});
                return error.MissingCreateType;
            }
            if (std.mem.eql(u8, args[2], "config")) {
                try createConfig(allocator);
            } else if (std.mem.eql(u8, args[2], "handler")) {
                if (args.len < 4) {
                    std.log.err("Usage: zails create handler <name>", .{});
                    return error.MissingHandlerName;
                }
                try createHandler(allocator, args[3]);
            } else if (std.mem.eql(u8, args[2], "model")) {
                if (args.len < 4) {
                    std.log.err("Usage: zails create model <name> [--table=table_name]", .{});
                    return error.MissingModelName;
                }
                const table_name = if (args.len > 4 and std.mem.startsWith(u8, args[4], "--table="))
                    args[4][8..]
                else
                    null;
                try createModel(allocator, args[3], table_name);
            } else if (std.mem.eql(u8, args[2], "migration")) {
                if (args.len < 4) {
                    std.log.err("Usage: zails create migration <name>", .{});
                    return error.MissingMigrationName;
                }
                try createMigration(allocator, args[3]);
            } else if (std.mem.eql(u8, args[2], "service")) {
                if (args.len < 4) {
                    std.log.err("Usage: zails create service <name>", .{});
                    return error.MissingServiceName;
                }
                try createService(allocator, args[3]);
            } else {
                std.log.err("Unknown create type: {s}", .{args[2]});
                return error.UnknownCreateType;
            }
        },
        .scaffold => {
            if (args.len < 3) {
                std.log.err("Usage: zails scaffold <resource> [--fields=field1:type1,field2:type2]", .{});
                return error.MissingResourceName;
            }
            const fields_arg = if (args.len > 3 and std.mem.startsWith(u8, args[3], "--fields="))
                args[3][9..]
            else
                null;
            try scaffoldResource(allocator, args[2], fields_arg);
        },
        .help => {
            printHelp();
        },
    }
}

fn printHelp() void {
    std.log.info(
        \\Zails - Convention-based server framework for Zig
        \\
        \\Usage:
        \\  zails init <project_name>                  - Create a new Zails project
        \\  zails build                                - Build the current project
        \\  zails create config                        - Generate config/ directory
        \\  zails create handler <name>                - Generate a new handler
        \\  zails create model <name> [--table=...]    - Generate a new ORM model
        \\  zails create migration <name>              - Generate a database migration
        \\  zails create service <name>                - Generate a gRPC service handler
        \\  zails scaffold <resource> [--fields=...]   - Generate full CRUD scaffold
        \\  zails help                                 - Show this help
        \\
        \\Examples:
        \\  zails init my-server
        \\  cd my-server
        \\  zails create model User --table=users
        \\  zails create service UserService
        \\  zails scaffold Post --fields=title:String,content:Text
        \\  zails build
        \\
    , .{});
}

fn initProject(project_name: []const u8) !void {
    std.log.info("Creating new Zails project: {s}", .{project_name});

    // Create project directory
    try fs.cwd().makeDir(project_name);
    var project_dir = try fs.cwd().openDir(project_name, .{});
    defer project_dir.close();

    // Create subdirectories
    try project_dir.makeDir("handlers");
    try project_dir.makeDir("views");
    try project_dir.makeDir("server");
    try project_dir.makeDir("src");

    std.log.info("  ✓ Created directory structure", .{});

    // Write embedded server framework files
    {
        var server_dir = try project_dir.openDir("server", .{});
        defer server_dir.close();

        for (embedded_server_files) |entry| {
            const dest_file = try server_dir.createFile(entry.name, .{});
            defer dest_file.close();
            try dest_file.writeAll(entry.content);
        }
    }

    std.log.info("  ✓ Copied server framework files", .{});

    // Create handlers/mod.zig
    try createHandlersMod(project_dir);
    std.log.info("  ✓ Created handlers/mod.zig", .{});

    // Create example handlers
    try createEchoHandler(project_dir);
    std.log.info("  ✓ Created handlers/echo_handler.zig", .{});

    try createPingHandler(project_dir);
    std.log.info("  ✓ Created handlers/ping_handler.zig", .{});

    // Create src/main.zig
    try createMainZig(project_dir);
    std.log.info("  ✓ Created src/main.zig", .{});

    // Create build.zig
    try createBuildZig(project_dir);
    std.log.info("  ✓ Created build.zig", .{});

    // Create README
    try createReadme(project_dir, project_name);
    std.log.info("  ✓ Created README.md", .{});

    std.log.info("", .{});
    std.log.info("✅ Project '{s}' created successfully!", .{project_name});
    std.log.info("", .{});
    std.log.info("Next steps:", .{});
    std.log.info("  cd {s}", .{project_name});
    std.log.info("  zails build", .{});
    std.log.info("  ./zig-out/bin/server --ports 8080", .{});
    std.log.info("", .{});
}

fn createHandlersMod(project_dir: fs.Dir) !void {
    var handlers_dir = try project_dir.openDir("handlers", .{});
    defer handlers_dir.close();

    const content =
        \\/// Handlers module - AUTO-GENERATED by `zails build`
        \\/// DO NOT EDIT MANUALLY - changes will be overwritten
        \\///
        \\/// To add a new handler:
        \\///   1. Drop a .zig file in handlers/ directory
        \\///   2. Export MESSAGE_TYPE, Context, and handle() function
        \\///   3. Run `zails build`
        \\
        \\
        \\const std = @import("std");
        \\
        \\// Auto-imported handler modules
        \\pub const echo_handler = @import("echo_handler.zig");
        \\pub const ping_handler = @import("ping_handler.zig");
        \\
        \\/// List of all handler modules (compile-time)
        \\/// This tuple is used by HandlerRegistry for comptime dispatch
        \\pub const handler_modules = .{
        \\    echo_handler,
        \\    ping_handler,
        \\};
        \\
        \\/// Helper: get list of all registered message types (compile-time)
        \\pub fn getAllMessageTypes() []const u8 {
        \\    comptime {
        \\        var types: [handler_modules.len]u8 = undefined;
        \\        for (handler_modules, 0..) |handler_module, i| {
        \\            types[i] = handler_module.MESSAGE_TYPE;
        \\        }
        \\        const final = types;
        \\        return &final;
        \\    }
        \\}
        \\
        \\/// Helper: get handler count (compile-time)
        \\pub fn getHandlerCount() comptime_int {
        \\    return handler_modules.len;
        \\}
        \\
        \\// Compile-time validation
        \\comptime {
        \\    // Ensure no duplicate message types
        \\    const types = getAllMessageTypes();
        \\    for (types, 0..) |type_a, i| {
        \\        for (types[i + 1 ..]) |type_b| {
        \\            if (type_a == type_b) {
        \\                @compileError("Duplicate message type detected!");
        \\            }
        \\        }
        \\    }
        \\}
        \\
    ;

    const file = try handlers_dir.createFile("mod.zig", .{});
    defer file.close();
    try file.writeAll(content);
}

fn createEchoHandler(project_dir: fs.Dir) !void {
    var handlers_dir = try project_dir.openDir("handlers", .{});
    defer handlers_dir.close();

    const content =
        \\/// Echo Handler - echoes messages back to client
        \\/// Tiger Style: NEVER THROWS - all errors are values
        \\
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\const result = @import("result");
        \\
        \\// Message type ID for echo requests
        \\pub const MESSAGE_TYPE: u8 = 1;
        \\
        \\// Handler context (shared state)
        \\pub const Context = struct {
        \\    request_count: std.atomic.Value(u64),
        \\
        \\    pub fn init() Context {
        \\        return .{
        \\            .request_count = std.atomic.Value(u64).init(0),
        \\        };
        \\    }
        \\
        \\    pub fn deinit(self: *Context) void {
        \\        _ = self;
        \\    }
        \\};
        \\
        \\// Handle echo request (Tiger Style - NEVER THROWS)
        \\pub fn handle(
        \\    context: *Context,
        \\    request_data: []const u8,
        \\    response_buffer: []u8,
        \\    allocator: Allocator,
        \\) result.HandlerResponse {
        \\    _ = context.request_count.fetchAdd(1, .monotonic);
        \\    _ = allocator;
        \\
        \\    // Echo: copy request to response
        \\    const len = @min(request_data.len, response_buffer.len);
        \\    @memcpy(response_buffer[0..len], request_data[0..len]);
        \\    return result.HandlerResponse.ok(response_buffer[0..len]);
        \\}
        \\
    ;

    const file = try handlers_dir.createFile("echo_handler.zig", .{});
    defer file.close();
    try file.writeAll(content);
}

fn createPingHandler(project_dir: fs.Dir) !void {
    var handlers_dir = try project_dir.openDir("handlers", .{});
    defer handlers_dir.close();

    const content =
        \\/// Ping Handler - simple health check
        \\/// Tiger Style: NEVER THROWS - all errors are values
        \\
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\const result = @import("result");
        \\
        \\// Message type ID for ping requests
        \\pub const MESSAGE_TYPE: u8 = 2;
        \\
        \\// Handler context
        \\pub const Context = struct {
        \\    start_time: i64,
        \\
        \\    pub fn init() Context {
        \\        return .{
        \\            .start_time = std.time.milliTimestamp(),
        \\        };
        \\    }
        \\
        \\    pub fn deinit(self: *Context) void {
        \\        _ = self;
        \\    }
        \\};
        \\
        \\// Handle ping request (Tiger Style - NEVER THROWS)
        \\pub fn handle(
        \\    context: *Context,
        \\    request_data: []const u8,
        \\    response_buffer: []u8,
        \\    allocator: Allocator,
        \\) result.HandlerResponse {
        \\    _ = request_data;
        \\    _ = allocator;
        \\
        \\    const uptime = std.time.milliTimestamp() - context.start_time;
        \\
        \\    const response = std.fmt.bufPrint(
        \\        response_buffer,
        \\        "PONG uptime={}ms",
        \\        .{uptime},
        \\    ) catch {
        \\        return result.HandlerResponse.err(.handler_failed);
        \\    };
        \\
        \\    return result.HandlerResponse.ok(response);
        \\}
        \\
    ;

    const file = try handlers_dir.createFile("ping_handler.zig", .{});
    defer file.close();
    try file.writeAll(content);
}

fn createMainZig(project_dir: fs.Dir) !void {
    var src_dir = try project_dir.openDir("src", .{});
    defer src_dir.close();

    const content =
        \\/// Main entry point - Convention-based server framework
        \\/// Handlers are auto-discovered from handlers/ folder at compile time
        \\
        \\const std = @import("std");
        \\const Config = @import("../server/config.zig").Config;
        \\const SignalHandler = @import("../server/signals.zig").SignalHandler;
        \\const numa = @import("../server/numa.zig");
        \\const epoll_threadpool = @import("../server/epoll_threadpool.zig");
        \\const handler_registry = @import("../server/handler_registry.zig");
        \\const net = std.net;
        \\
        \\// Import all handlers from handlers/ folder
        \\const handlers = @import("../handlers/mod.zig");
        \\
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer _ = gpa.deinit();
        \\    const allocator = gpa.allocator();
        \\
        \\    std.log.info("=== Zails - High-Performance Server Framework ===" , .{});
        \\    std.log.info("Features:", .{});
        \\    std.log.info("  ✓ Convention-based handlers (handlers/ folder)", .{});
        \\    std.log.info("  ✓ Comptime dispatch (NO virtual inheritance)", .{});
        \\    std.log.info("  ✓ Lock-free object pools", .{});
        \\    std.log.info("  ✓ Lock-free threadpool with work-stealing", .{});
        \\    std.log.info("  ✓ NUMA-aware worker placement", .{});
        \\    std.log.info("", .{});
        \\
        \\    // Parse configuration
        \\    const args = try std.process.argsAlloc(allocator);
        \\    defer std.process.argsFree(allocator, args);
        \\
        \\    var config = Config.parseArgs(allocator, args) catch |err| {
        \\        if (err == error.HelpRequested) {
        \\            return;
        \\        }
        \\        std.log.err("Failed to parse arguments: {}", .{err});
        \\        return err;
        \\    };
        \\    defer config.deinit(allocator);
        \\
        \\    try config.validate();
        \\
        \\    // Create handler registry (comptime dispatch from handlers/ folder)
        \\    const Registry = handler_registry.HandlerRegistry(handlers.handler_modules);
        \\    var registry = try Registry.init(allocator);
        \\    defer registry.deinit();
        \\
        \\    std.log.info("Configuration:", .{});
        \\    std.log.info("  Ports: {any}", .{config.ports});
        \\    std.log.info("  Workers: {any}", .{config.worker_threads});
        \\    std.log.info("  NUMA enabled: {}", .{config.enable_numa});
        \\    std.log.info("  Handlers: {}", .{Registry.getHandlerCount()});
        \\    std.log.info("  Message types: {any}", .{Registry.getAllMessageTypes()});
        \\    std.log.info("", .{});
        \\
        \\    // Detect NUMA topology
        \\    var topology = try numa.NumaTopology.detect(allocator);
        \\    defer topology.deinit();
        \\
        \\    const total_workers = config.worker_threads orelse (topology.total_cpus * 2);
        \\    const workers_per_node = @max(1, total_workers / topology.nodes.len);
        \\
        \\    std.log.info("NUMA topology: {} nodes, {} CPUs, {} workers per node", .{
        \\        topology.nodes.len,
        \\        topology.total_cpus,
        \\        workers_per_node,
        \\    });
        \\
        \\    // Connection tracking
        \\    var active_connections = std.atomic.Value(usize).init(0);
        \\
        \\    // Create event-driven epoll thread pools (one per NUMA node)
        \\    var thread_pools = try allocator.alloc(
        \\        epoll_threadpool.EpollThreadPool,
        \\        topology.nodes.len,
        \\    );
        \\    defer allocator.free(thread_pools);
        \\
        \\    for (topology.nodes, 0..) |node, i| {
        \\        thread_pools[i] = try epoll_threadpool.EpollThreadPool.init(
        \\            allocator,
        \\            node,
        \\            workers_per_node,
        \\            &registry,
        \\            &active_connections,
        \\        );
        \\    }
        \\
        \\    defer {
        \\        for (thread_pools) |*pool| {
        \\            pool.deinit();
        \\        }
        \\    }
        \\
        \\    // Create listeners
        \\    var listeners = try allocator.alloc(net.Server, config.ports.len);
        \\    defer allocator.free(listeners);
        \\
        \\    for (config.ports, 0..) |port, i| {
        \\        const address = try net.Address.parseIp("0.0.0.0", port);
        \\        listeners[i] = try address.listen(.{ .reuse_address = true });
        \\        std.log.info("Listening on port {}", .{port});
        \\    }
        \\
        \\    defer {
        \\        for (listeners) |*listener| {
        \\            listener.deinit();
        \\        }
        \\    }
        \\
        \\    var shutdown = std.atomic.Value(bool).init(false);
        \\
        \\    // Setup signal handlers for graceful shutdown
        \\    var signal_handler = SignalHandler.init(&shutdown);
        \\    signal_handler.register();
        \\
        \\    std.log.info("", .{});
        \\    std.log.info("=== Server Running ===", .{});
        \\    std.log.info("Processing requests with:", .{});
        \\    std.log.info("  • Zero allocations (lock-free object pools)", .{});
        \\    std.log.info("  • Zero syscalls in hot path", .{});
        \\    std.log.info("  • Zero virtual inheritance (comptime dispatch)", .{});
        \\    std.log.info("Press Ctrl+C to shutdown", .{});
        \\    std.log.info("", .{});
        \\
        \\    // Accept loop
        \\    var connection_count: usize = 0;
        \\
        \\    while (!shutdown.load(.acquire)) {
        \\        for (listeners, 0..) |*listener, i| {
        \\            const connection = listener.accept() catch continue;
        \\
        \\            // Route to NUMA-local threadpool (epoll-based)
        \\            const node_idx = i % topology.nodes.len;
        \\            thread_pools[node_idx].spawn(connection) catch |err| {
        \\                std.log.err("Failed to add connection to epoll: {}", .{err});
        \\                connection.stream.close();
        \\                continue;
        \\            };
        \\
        \\            connection_count += 1;
        \\
        \\            if (connection_count % 10000 == 0) {
        \\                std.log.info("Processed {} connections", .{connection_count});
        \\            }
        \\        }
        \\    }
        \\
        \\    std.log.info("Shutting down...", .{});
        \\    std.log.info("Total connections processed: {}", .{connection_count});
        \\}
        \\
    ;

    const file = try src_dir.createFile("main.zig", .{});
    defer file.close();
    try file.writeAll(content);
}

fn createBuildZig(project_dir: fs.Dir) !void {
    const content =
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    // Create root module
        \\    const root_module = b.createModule(.{
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\
        \\    // Main server executable
        \\    const exe = b.addExecutable(.{
        \\        .name = "server",
        \\        .root_module = root_module,
        \\    });
        \\
        \\    b.installArtifact(exe);
        \\
        \\    // Run command
        \\    const run_cmd = b.addRunArtifact(exe);
        \\    run_cmd.step.dependOn(b.getInstallStep());
        \\
        \\    if (b.args) |args| {
        \\        run_cmd.addArgs(args);
        \\    }
        \\
        \\    const run_step = b.step("run", "Run the server");
        \\    run_step.dependOn(&run_cmd.step);
        \\
        \\    // Client executable
        \\    const client_module = b.createModule(.{
        \\        .root_source_file = b.path("server/client.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\
        \\    const client_exe = b.addExecutable(.{
        \\        .name = "client",
        \\        .root_module = client_module,
        \\    });
        \\
        \\    b.installArtifact(client_exe);
        \\
        \\    const client_run_cmd = b.addRunArtifact(client_exe);
        \\    client_run_cmd.step.dependOn(b.getInstallStep());
        \\
        \\    if (b.args) |args| {
        \\        client_run_cmd.addArgs(args);
        \\    }
        \\
        \\    const client_run_step = b.step("run-client", "Run the client");
        \\    client_run_step.dependOn(&client_run_cmd.step);
        \\}
        \\
    ;

    const file = try project_dir.createFile("build.zig", .{});
    defer file.close();
    try file.writeAll(content);
}

fn createReadme(project_dir: fs.Dir, project_name: []const u8) !void {
    const page_alloc = std.heap.page_allocator;
    const content = std.fmt.allocPrint(
        page_alloc,
        \\# {s}
        \\
        \\A high-performance server built with Zails framework.
        \\
        \\## Quick Start
        \\
        \\```bash
        \\# Build
        \\zails build
        \\
        \\# Run
        \\./zig-out/bin/server --ports 8080
        \\
        \\# Test
        \\./zig-out/bin/client 8080 "Hello!"
        \\```
        \\
        \\## Adding Handlers
        \\
        \\Simply drop a new `.zig` file in the `handlers/` directory and run `zails build`:
        \\
        \\1. Create a new file in `handlers/` (e.g., `my_handler.zig`)
        \\2. Export `MESSAGE_TYPE`, `Context`, and `handle()` function
        \\3. Run `zails build` - handlers/mod.zig is auto-generated!
        \\
        \\No manual editing of mod.zig needed. See `handlers/echo_handler.zig` for an example.
        \\
        \\## Architecture
        \\
        \\- **Convention-based**: Handlers auto-discovered from `handlers/` folder
        \\- **Comptime dispatch**: Zero runtime overhead, no virtual inheritance
        \\- **Lock-free**: Atomic operations, no mutexes
        \\- **Zero allocations**: Pre-allocated object pools
        \\- **NUMA-aware**: Automatic CPU pinning
        \\
        \\## Documentation
        \\
        \\For full Zails framework documentation, see: https://github.com/yourorg/zails
        \\
    , .{project_name}) catch return error.OutOfMemory;
    defer page_alloc.free(content);

    const file = try project_dir.createFile("README.md", .{});
    defer file.close();
    try file.writeAll(content);
}

fn buildProject() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Building project...", .{});

    // Step 1: Auto-generate handlers/mod.zig
    try regenerateHandlersMod(allocator);

    // Step 2: Run zig build
    const result = try std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "zig", "build" },
    });

    const build_failed = switch (result.term) {
        .Exited => |code| code != 0,
        else => true,
    };

    if (build_failed) {
        std.log.err("Build failed:\n{s}", .{result.stderr});
        return error.BuildFailed;
    }

    std.log.info("{s}", .{result.stdout});
    std.log.info("✅ Build successful!", .{});
}

fn regenerateHandlersMod(allocator: Allocator) !void {
    std.log.info("Auto-generating handlers/mod.zig...", .{});

    // Scan handlers/ directory for .zig files (except mod.zig)
    var handlers_dir = try fs.cwd().openDir("handlers", .{ .iterate = true });
    defer handlers_dir.close();

    var handler_files = std.ArrayList([]const u8){};
    defer {
        for (handler_files.items) |file| {
            allocator.free(file);
        }
        handler_files.deinit(allocator);
    }

    var iter = handlers_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "mod.zig")) continue;

        // Remove .zig extension to get module name
        const module_name = entry.name[0 .. entry.name.len - 4];
        try handler_files.append(allocator, try allocator.dupe(u8, module_name));
    }

    // Sort handler files alphabetically for consistent output
    std.mem.sort([]const u8, handler_files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    std.log.info("  Found {} handlers", .{handler_files.items.len});

    // Generate handlers/mod.zig
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    const writer = output.writer(allocator);

    // Header
    try writer.writeAll(
        \\/// Handlers module - AUTO-GENERATED by `zails build`
        \\/// DO NOT EDIT MANUALLY - changes will be overwritten
        \\///
        \\/// To add a new handler:
        \\///   1. Drop a .zig file in handlers/ directory
        \\///   2. Export MESSAGE_TYPE, Context, and handle() function
        \\///   3. Run `zails build`
        \\
        \\
        \\const std = @import("std");
        \\
        \\// Auto-imported handler modules
        \\
    );

    // Import statements
    for (handler_files.items) |module_name| {
        try writer.print("pub const {s} = @import(\"{s}.zig\");\n", .{ module_name, module_name });
    }

    try writer.writeAll("\n/// List of all handler modules (compile-time)\n");
    try writer.writeAll("/// This tuple is used by HandlerRegistry for comptime dispatch\n");
    try writer.writeAll("pub const handler_modules = .{\n");

    // Handler modules tuple
    for (handler_files.items) |module_name| {
        try writer.print("    {s},\n", .{module_name});
    }

    try writer.writeAll("};\n\n");

    // Helper functions
    try writer.writeAll(
        \\/// Helper: get list of all registered message types (compile-time)
        \\pub fn getAllMessageTypes() []const u8 {
        \\    comptime {
        \\        var types: [handler_modules.len]u8 = undefined;
        \\        for (handler_modules, 0..) |handler_module, i| {
        \\            types[i] = handler_module.MESSAGE_TYPE;
        \\        }
        \\        const final = types;
        \\        return &final;
        \\    }
        \\}
        \\
        \\/// Helper: get handler count (compile-time)
        \\pub fn getHandlerCount() comptime_int {
        \\    return handler_modules.len;
        \\}
        \\
        \\// Compile-time validation
        \\comptime {
        \\    // Ensure no duplicate message types
        \\    const types = getAllMessageTypes();
        \\    for (types, 0..) |type_a, i| {
        \\        for (types[i + 1 ..]) |type_b| {
        \\            if (type_a == type_b) {
        \\                @compileError("Duplicate message type detected!");
        \\            }
        \\        }
        \\    }
        \\}
        \\
    );

    // Write to handlers/mod.zig
    const mod_file = try handlers_dir.createFile("mod.zig", .{});
    defer mod_file.close();
    try mod_file.writeAll(output.items);

    std.log.info("  ✓ Generated handlers/mod.zig with {} handlers", .{handler_files.items.len});
}

fn createConfig(allocator: Allocator) !void {
    std.log.info("Creating config/ directory...", .{});

    // Create config directory (if it doesn't exist)
    fs.cwd().makeDir("config") catch |err| {
        if (err != error.PathAlreadyExists) return err;
        std.log.info("  Config directory already exists", .{});
    };

    var config_dir = try fs.cwd().openDir("config", .{});
    defer config_dir.close();

    // Check if zails.yaml already exists
    const config_exists = blk: {
        const file = config_dir.openFile("zails.yaml", .{}) catch |err| {
            if (err == error.FileNotFound) {
                break :blk false;
            }
            return err;
        };
        file.close();
        break :blk true;
    };

    if (config_exists) {
        std.log.warn("  config/zails.yaml already exists - not overwriting", .{});
        std.log.info("  Tip: Delete config/zails.yaml first to regenerate", .{});
        return;
    }

    // Scan existing handlers
    var handler_list = try discoverHandlers(allocator);
    defer {
        for (handler_list.items) |name| {
            allocator.free(name);
        }
        handler_list.deinit(allocator);
    }

    // Generate zails.yaml with handler configs
    var yaml_buffer = std.ArrayList(u8){};
    defer yaml_buffer.deinit(allocator);
    const yaml_writer = yaml_buffer.writer(allocator);

    try yaml_writer.writeAll(
        \\# Zails Configuration
        \\# Edit this file to configure your server
        \\
        \\server:
        \\  ports: [8080, 8081]
        \\  worker_threads: auto  # or specify number
        \\  enable_numa: true
        \\  pool_size: 2048
        \\  max_connections: 10000
        \\  read_timeout_ms: 30000
        \\  write_timeout_ms: 30000
        \\
    );

    // Add handler configurations
    try yaml_writer.writeAll("\nhandlers:\n");
    if (handler_list.items.len > 0) {
        try yaml_writer.writeAll("  # Per-handler configuration\n");
        for (handler_list.items) |handler_name| {
            try yaml_writer.print("  {s}:\n", .{handler_name});
            try yaml_writer.writeAll("    enabled: true\n");
            try yaml_writer.writeAll("    rate_limit: 0  # 0 = unlimited, or requests/second\n");
            try yaml_writer.writeAll("    timeout_ms: 30000\n");
            try yaml_writer.writeAll("    max_payload_size: 4096  # bytes\n");
            try yaml_writer.writeAll("    # Add custom handler-specific config here\n\n");
        }
    } else {
        try yaml_writer.writeAll("  # No handlers found - run 'zails build' first\n");
        try yaml_writer.writeAll("  # Handler configs will be added when you create handlers\n");
    }
    try yaml_writer.writeAll("\n");

    const zails_yaml_start =
        \\
        \\metrics:
        \\  enabled: true
        \\  export_interval_seconds: 15
        \\  prometheus:
        \\    enabled: true
        \\    port: 9090
        \\    path: /metrics
        \\  statsd:
        \\    enabled: false
        \\    host: localhost
        \\    port: 8125
        \\    prefix: zails
        \\
        \\persistence:
        \\  enabled: false
        \\  backend: none  # none | redis | postgresql | sqlite | rocksdb
        \\  connection_string: ""
        \\  pool_size: 10
        \\  timeout_ms: 5000
        \\
        \\sla:
        \\  enabled: true
        \\  targets:
        \\    - name: "latency_p99"
        \\      metric: "zails_latency_max_microseconds"
        \\      threshold: 10000  # 10ms
        \\      window_seconds: 300  # 5 minutes
        \\      alert_channel: "webhook:http://localhost:9000/alerts"
        \\
        \\    - name: "error_rate"
        \\      metric: "zails_requests_failed"
        \\      threshold: 0.01  # 1%
        \\      window_seconds: 60
        \\      alert_channel: "log"
        \\
        \\    - name: "pool_exhaustion"
        \\      metric: "zails_pool_exhaustions"
        \\      threshold: 0
        \\      window_seconds: 60
        \\      alert_channel: "log"
        \\
        \\profiling:
        \\  enabled: false  # Can be toggled at runtime
        \\  cpu_profiling: false
        \\  memory_profiling: false
        \\  trace_sampling: false
        \\  sampling_rate: 0.01  # 1% of requests
        \\  export_flame_graphs: false
        \\
    ;

    try yaml_writer.writeAll(zails_yaml_start);

    var yaml_file = try config_dir.createFile("zails.yaml", .{});
    defer yaml_file.close();
    try yaml_file.writeAll(yaml_buffer.items);

    // Create alerts.yaml
    const alerts_yaml =
        \\# Prometheus Alert Rules
        \\# Use with: prometheus --config.file=prometheus.yml --rules.file=config/alerts.yaml
        \\
        \\groups:
        \\  - name: zails_alerts
        \\    interval: 30s
        \\    rules:
        \\      - alert: HighErrorRate
        \\        expr: rate(zails_requests_failed[5m]) / rate(zails_requests_total[5m]) > 0.01
        \\        for: 5m
        \\        labels:
        \\          severity: warning
        \\          team: backend
        \\        annotations:
        \\          summary: "High error rate detected"
        \\          description: "Error rate is {{ $value | humanizePercentage }}"
        \\
        \\      - alert: HighLatencyP99
        \\        expr: zails_latency_max_microseconds > 10000
        \\        for: 5m
        \\        labels:
        \\          severity: warning
        \\          team: backend
        \\        annotations:
        \\          summary: "High P99 latency detected"
        \\          description: "P99 latency is {{ $value }}µs (threshold: 10000µs)"
        \\
        \\      - alert: PoolExhaustion
        \\        expr: rate(zails_pool_exhaustions[1m]) > 0
        \\        for: 1m
        \\        labels:
        \\          severity: critical
        \\          team: backend
        \\        annotations:
        \\          summary: "Object pool exhausted"
        \\          description: "Increase --pool-size or investigate memory leak"
        \\
        \\      - alert: ServerDown
        \\        expr: up{job="zails"} == 0
        \\        for: 1m
        \\        labels:
        \\          severity: critical
        \\          team: oncall
        \\        annotations:
        \\          summary: "Zails server is down"
        \\          description: "Server has been unreachable for 1 minute"
        \\
        \\      - alert: HighConnectionRate
        \\        expr: rate(zails_connections_total[1m]) > 1000
        \\        for: 5m
        \\        labels:
        \\          severity: info
        \\          team: backend
        \\        annotations:
        \\          summary: "Unusual connection rate"
        \\          description: "Connection rate: {{ $value }} conn/sec"
        \\
    ;

    var alerts_file = try config_dir.createFile("alerts.yaml", .{});
    defer alerts_file.close();
    try alerts_file.writeAll(alerts_yaml);

    // Create persistence examples
    const persistence_examples =
        \\# Persistence Layer Examples
        \\
        \\# Redis
        \\# persistence:
        \\#   enabled: true
        \\#   backend: redis
        \\#   connection_string: "redis://localhost:6379/0"
        \\#   pool_size: 20
        \\#   timeout_ms: 5000
        \\
        \\# PostgreSQL
        \\# persistence:
        \\#   enabled: true
        \\#   backend: postgresql
        \\#   connection_string: "postgresql://user:pass@localhost:5432/zails"
        \\#   pool_size: 10
        \\#   timeout_ms: 10000
        \\
        \\# SQLite
        \\# persistence:
        \\#   enabled: true
        \\#   backend: sqlite
        \\#   connection_string: "/var/lib/zails/data.db"
        \\#   pool_size: 1
        \\#   timeout_ms: 5000
        \\
        \\# RocksDB
        \\# persistence:
        \\#   enabled: true
        \\#   backend: rocksdb
        \\#   connection_string: "/var/lib/zails/rocksdb"
        \\#   pool_size: 10
        \\#   timeout_ms: 1000
        \\
    ;

    var persistence_file = try config_dir.createFile("persistence-examples.yaml", .{});
    defer persistence_file.close();
    try persistence_file.writeAll(persistence_examples);

    // Create prometheus.yml
    const prometheus_yml =
        \\# Prometheus Configuration for Zails
        \\
        \\global:
        \\  scrape_interval: 15s
        \\  evaluation_interval: 15s
        \\  external_labels:
        \\    cluster: 'production'
        \\    service: 'zails'
        \\
        \\# Alertmanager configuration
        \\alerting:
        \\  alertmanagers:
        \\    - static_configs:
        \\        - targets:
        \\          - localhost:9093
        \\
        \\# Load alert rules
        \\rule_files:
        \\  - "config/alerts.yaml"
        \\
        \\# Scrape configurations
        \\scrape_configs:
        \\  - job_name: 'zails'
        \\    static_configs:
        \\      - targets: ['localhost:9999']
        \\    # Assuming metrics are on message type 255
        \\    # You may need to set up an HTTP proxy to Prometheus format
        \\
    ;

    var prometheus_file = try config_dir.createFile("prometheus.yml", .{});
    defer prometheus_file.close();
    try prometheus_file.writeAll(prometheus_yml);

    // Create README
    const readme =
        \\# Configuration Guide
        \\
        \\This directory contains Zails configuration files.
        \\
        \\## Files
        \\
        \\- **zails.yaml** - Main server configuration
        \\- **alerts.yaml** - Prometheus alert rules
        \\- **prometheus.yml** - Prometheus scraping configuration
        \\- **persistence-examples.yaml** - Database connection examples
        \\
        \\## Usage
        \\
        \\1. Edit `zails.yaml` to configure your server
        \\2. Start server with config:
        \\   ```
        \\   ./zig-out/bin/server --config config/zails.yaml
        \\   ```
        \\3. Start Prometheus (for metrics):
        \\   ```
        \\   prometheus --config.file=config/prometheus.yml
        \\   ```
        \\
        \\## Runtime Configuration
        \\
        \\Some settings can be changed at runtime using the control handler:
        \\
        \\```bash
        \\# Disable profiling
        \\echo "profiling:disable" | nc localhost 9999
        \\
        \\# Enable metrics
        \\echo "metrics:enable" | nc localhost 9999
        \\```
        \\
        \\See METRICS_GUIDE.md for more details.
        \\
    ;

    var readme_file = try config_dir.createFile("README.md", .{});
    defer readme_file.close();
    try readme_file.writeAll(readme);

    std.log.info("", .{});
    std.log.info("✅ Configuration directory created!", .{});
    std.log.info("", .{});
    std.log.info("Files created:", .{});
    std.log.info("  config/zails.yaml             - Main configuration", .{});
    std.log.info("  config/alerts.yaml             - Prometheus alerts", .{});
    std.log.info("  config/prometheus.yml          - Prometheus config", .{});
    std.log.info("  config/persistence-examples.yaml - DB examples", .{});
    std.log.info("  config/README.md               - Configuration guide", .{});
    std.log.info("", .{});
    std.log.info("Next steps:", .{});
    std.log.info("  1. Edit config/zails.yaml", .{});
    std.log.info("  2. Run: ./zig-out/bin/server --config config/zails.yaml", .{});
    std.log.info("", .{});
}

fn discoverHandlers(allocator: Allocator) !std.ArrayList([]const u8) {
    var handler_list = std.ArrayList([]const u8){};

    var handlers_dir = fs.cwd().openDir("handlers", .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            return handler_list; // No handlers directory yet
        }
        return err;
    };
    defer handlers_dir.close();

    var iter = handlers_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "mod.zig")) continue;

        // Remove .zig extension
        const name_without_ext = entry.name[0 .. entry.name.len - 4];
        const name_copy = try allocator.dupe(u8, name_without_ext);
        try handler_list.append(allocator, name_copy);
    }

    return handler_list;
}

fn createHandler(allocator: Allocator, name: []const u8) !void {
    std.log.info("Creating handler: {s}", .{name});

    // Create handlers directory if it doesn't exist
    fs.cwd().makeDir("handlers") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Create handler file
    var handlers_dir = try fs.cwd().openDir("handlers", .{});
    defer handlers_dir.close();

    // Check if handler already exists
    const filename = try std.fmt.allocPrint(allocator, "{s}.zig", .{name});
    defer allocator.free(filename);

    const handler_exists = blk: {
        const file = handlers_dir.openFile(filename, .{}) catch |err| {
            if (err == error.FileNotFound) {
                break :blk false;
            }
            return err;
        };
        file.close();
        break :blk true;
    };

    if (handler_exists) {
        std.log.err("Handler already exists: handlers/{s}", .{filename});
        return error.HandlerAlreadyExists;
    }

    // Find next available MESSAGE_TYPE
    const next_msg_type = findNextMessageType(allocator) catch 10;

    // Generate handler code (Tiger Style)
    const template = try std.fmt.allocPrint(
        allocator,
        \\/// {s} handler
        \\/// Tiger Style: NEVER THROWS - all errors are values
        \\
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\const result = @import("result");
        \\
        \\pub const MESSAGE_TYPE: u8 = {d};
        \\
        \\pub const Context = struct {{
        \\    request_count: std.atomic.Value(u64),
        \\
        \\    pub fn init() Context {{
        \\        return .{{
        \\            .request_count = std.atomic.Value(u64).init(0),
        \\        }};
        \\    }}
        \\
        \\    pub fn deinit(self: *Context) void {{
        \\        _ = self;
        \\    }}
        \\}};
        \\
        \\pub fn handle(
        \\    context: *Context,
        \\    request_data: []const u8,
        \\    response_buffer: []u8,
        \\    allocator: Allocator,
        \\) result.HandlerResponse {{
        \\    _ = context.request_count.fetchAdd(1, .monotonic);
        \\    _ = allocator;
        \\
        \\    // TODO: Implement your handler logic here
        \\
        \\    // Echo example:
        \\    const len = @min(request_data.len, response_buffer.len);
        \\    @memcpy(response_buffer[0..len], request_data[0..len]);
        \\    return result.HandlerResponse.ok(response_buffer[0..len]);
        \\}}
        \\
    ,
        .{ name, next_msg_type },
    );
    defer allocator.free(template);

    var handler_file = try handlers_dir.createFile(filename, .{});
    defer handler_file.close();
    try handler_file.writeAll(template);

    std.log.info("  ✓ Created handlers/{s}", .{filename});

    // Update config if it exists
    const config_updated = updateConfigWithHandler(allocator, name) catch |err| blk: {
        std.log.warn("  Could not update config: {}", .{err});
        break :blk false;
    };

    std.log.info("", .{});
    std.log.info("✅ Handler created: handlers/{s}", .{filename});
    if (config_updated) {
        std.log.info("  ✓ Updated config/zails.yaml with handler settings", .{});
    }
    std.log.info("", .{});
    std.log.info("Next steps:", .{});
    std.log.info("  1. Edit handlers/{s}", .{filename});
    std.log.info("  2. Change MESSAGE_TYPE to unique value", .{});
    std.log.info("  3. Implement handle() function", .{});
    std.log.info("  4. Run: zails build", .{});
    std.log.info("", .{});
}

fn updateConfigWithHandler(allocator: Allocator, handler_name: []const u8) !bool {
    // Check if config exists
    var config_dir = fs.cwd().openDir("config", .{}) catch {
        return false; // No config directory
    };
    defer config_dir.close();

    const config_file = config_dir.openFile("zails.yaml", .{ .mode = .read_write }) catch {
        return false; // No config file
    };
    defer config_file.close();

    // Read existing config
    const content = try config_file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Check if handler already in config
    const search = try std.fmt.allocPrint(allocator, "  {s}:", .{handler_name});
    defer allocator.free(search);

    if (std.mem.indexOf(u8, content, search) != null) {
        return false; // Handler already in config
    }

    // Find handlers section
    const handlers_section = "handlers:\n";
    const handlers_pos = std.mem.indexOf(u8, content, handlers_section) orelse {
        return false; // No handlers section
    };

    // Find end of handlers section (next top-level key)
    const insert_pos = blk: {
        var pos = handlers_pos + handlers_section.len;
        while (pos < content.len) {
            // Look for next non-indented line
            if (content[pos] == '\n' and pos + 1 < content.len and content[pos + 1] != ' ' and content[pos + 1] != '\n') {
                break :blk pos + 1;
            }
            pos += 1;
        }
        break :blk content.len;
    };

    // Generate handler config
    const handler_config = try std.fmt.allocPrint(allocator,
        \\  {s}:
        \\    enabled: true
        \\    rate_limit: 0  # 0 = unlimited, or requests/second
        \\    timeout_ms: 30000
        \\    max_payload_size: 4096  # bytes
        \\    # Add custom handler-specific config here
        \\
        \\
    , .{handler_name});
    defer allocator.free(handler_config);

    // Create new content
    var new_content = std.ArrayList(u8){};
    defer new_content.deinit(allocator);

    try new_content.appendSlice(allocator, content[0..insert_pos]);
    try new_content.appendSlice(allocator, handler_config);
    try new_content.appendSlice(allocator, content[insert_pos..]);

    // Write back to file
    try config_file.seekTo(0);
    try config_file.setEndPos(0);
    try config_file.writeAll(new_content.items);

    return true;
}

// ============================================================================
// New Generator Functions
// ============================================================================

fn createModel(allocator: Allocator, name: []const u8, table_name_opt: ?[]const u8) !void {
    std.log.info("Creating model: {s}", .{name});

    // Create models directory if it doesn't exist
    fs.cwd().makeDir("models") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const table_name = table_name_opt orelse blk: {
        // Convert CamelCase to snake_case for table name
        var snake_case = try allocator.alloc(u8, name.len * 2);
        defer allocator.free(snake_case);

        var idx: usize = 0;
        for (name, 0..) |c, i| {
            if (i > 0 and std.ascii.isUpper(c)) {
                snake_case[idx] = '_';
                idx += 1;
            }
            snake_case[idx] = std.ascii.toLower(c);
            idx += 1;
        }

        break :blk try allocator.dupe(u8, snake_case[0..idx]);
    };
    defer if (table_name_opt == null) allocator.free(table_name);

    // Generate model file
    const filename = try std.fmt.allocPrint(allocator, "models/{s}.zig", .{name});
    defer allocator.free(filename);

    var model_file = try fs.cwd().createFile(filename, .{});
    defer model_file.close();

    // Read template and replace placeholders
    const template = @embedFile("templates/model.zig.template");
    const content = try std.mem.replaceOwned(u8, allocator, template, "{MODEL_NAME}", name);
    defer allocator.free(content);

    const content2 = try std.mem.replaceOwned(u8, allocator, content, "{TABLE_NAME}", table_name);
    defer allocator.free(content2);

    try model_file.writeAll(content2);

    std.log.info("  ✓ Created {s}", .{filename});
    std.log.info("", .{});
    std.log.info("✅ Model created successfully!", .{});
    std.log.info("  Edit {s} to add fields", .{filename});
    std.log.info("", .{});
}

fn createMigration(allocator: Allocator, name: []const u8) !void {
    std.log.info("Creating migration: {s}", .{name});

    // Create migrations directory if it doesn't exist
    fs.cwd().makeDir("migrations") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Generate timestamped filename
    const timestamp = std.time.timestamp();
    const filename = try std.fmt.allocPrint(
        allocator,
        "migrations/{d}_{s}.sql",
        .{ timestamp, name },
    );
    defer allocator.free(filename);

    var migration_file = try fs.cwd().createFile(filename, .{});
    defer migration_file.close();

    // Read template and replace placeholders
    const template = @embedFile("templates/migration.sql.template");
    const content = try std.mem.replaceOwned(u8, allocator, template, "{MIGRATION_NAME}", name);
    defer allocator.free(content);

    // Generate timestamp string
    const timestamp_str = try std.fmt.allocPrint(allocator, "{d}", .{timestamp});
    defer allocator.free(timestamp_str);

    const content2 = try std.mem.replaceOwned(u8, allocator, content, "{TIMESTAMP}", timestamp_str);
    defer allocator.free(content2);

    // Generate table name from migration name
    // Strip common prefixes like "create_", "add_", "alter_" to derive the table name
    const table_name = blk: {
        const prefixes = [_][]const u8{ "create_", "add_", "alter_", "drop_", "update_" };
        var stripped = name;
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, name, prefix)) {
                stripped = name[prefix.len..];
                break;
            }
        }
        break :blk try allocator.dupe(u8, stripped);
    };
    defer allocator.free(table_name);

    const content3 = try std.mem.replaceOwned(u8, allocator, content2, "{TABLE_NAME}", table_name);
    defer allocator.free(content3);

    try migration_file.writeAll(content3);

    std.log.info("  ✓ Created {s}", .{filename});
    std.log.info("", .{});
    std.log.info("✅ Migration created successfully!", .{});
    std.log.info("", .{});
}

fn createService(allocator: Allocator, name: []const u8) !void {
    std.log.info("Creating gRPC service: {s}", .{name});

    // Create services directory if it doesn't exist
    fs.cwd().makeDir("services") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Generate handler filename
    const handler_filename = try std.fmt.allocPrint(allocator, "handlers/{s}_handler.zig", .{name});
    defer allocator.free(handler_filename);

    var handler_file = try fs.cwd().createFile(handler_filename, .{});
    defer handler_file.close();

    // Find next available MESSAGE_TYPE
    const next_msg_type = try findNextMessageType(allocator);

    // Read template and replace placeholders
    const template = @embedFile("templates/service_handler.zig.template");
    const content = try std.mem.replaceOwned(u8, allocator, template, "{SERVICE_NAME}", name);
    defer allocator.free(content);

    const msg_type_str = try std.fmt.allocPrint(allocator, "{d}", .{next_msg_type});
    defer allocator.free(msg_type_str);

    const content2 = try std.mem.replaceOwned(u8, allocator, content, "{MESSAGE_TYPE}", msg_type_str);
    defer allocator.free(content2);

    try handler_file.writeAll(content2);

    std.log.info("  ✓ Created {s} (MESSAGE_TYPE={d})", .{ handler_filename, next_msg_type });
    std.log.info("", .{});
    std.log.info("✅ Service created successfully!", .{});
    std.log.info("  Run 'zails build' to register the handler", .{});
    std.log.info("", .{});
}

fn scaffoldResource(allocator: Allocator, resource: []const u8, fields_opt: ?[]const u8) !void {
    std.log.info("Scaffolding resource: {s}", .{resource});
    _ = fields_opt;

    // Generate model
    try createModel(allocator, resource, null);

    // Generate migration
    const migration_name = try std.fmt.allocPrint(allocator, "create_{s}", .{resource});
    defer allocator.free(migration_name);
    try createMigration(allocator, migration_name);

    // Generate service
    const service_name = try std.fmt.allocPrint(allocator, "{s}Service", .{resource});
    defer allocator.free(service_name);
    try createService(allocator, service_name);

    std.log.info("", .{});
    std.log.info("✅ Full scaffold created for {s}!", .{resource});
    std.log.info("  - models/{s}.zig", .{resource});
    std.log.info("  - migrations/xxx_create_{s}.sql", .{resource});
    std.log.info("  - handlers/{s}Service_handler.zig", .{resource});
    std.log.info("", .{});
    std.log.info("Run 'zails build' to compile", .{});
    std.log.info("", .{});
}

fn findNextMessageType(allocator: Allocator) !u8 {
    var handlers_dir = fs.cwd().openDir("handlers", .{ .iterate = true }) catch {
        return 10; // Default starting MESSAGE_TYPE
    };
    defer handlers_dir.close();

    var max_type: u8 = 9;

    var iter = handlers_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "mod.zig")) continue;

        // Read file and look for MESSAGE_TYPE
        const content = handlers_dir.readFileAlloc(allocator, entry.name, 1024 * 1024) catch continue;
        defer allocator.free(content);

        // Simple search for "MESSAGE_TYPE: u8 = XXX"
        if (std.mem.indexOf(u8, content, "MESSAGE_TYPE: u8 = ")) |pos| {
            const start = pos + 19;
            var end = start;
            while (end < content.len and std.ascii.isDigit(content[end])) {
                end += 1;
            }

            if (end > start) {
                const num_str = content[start..end];
                const num = std.fmt.parseInt(u8, num_str, 10) catch continue;
                if (num > max_type) {
                    max_type = num;
                }
            }
        }
    }

    if (max_type >= 253) {
        // Reserve 254 (control) and 255 (metrics)
        std.log.err("MESSAGE_TYPE space exhausted (max is 253, current max is {d})", .{max_type});
        return error.MessageTypeExhausted;
    }
    return max_type + 1;
}


