/// Comprehensive test harness for Zerver
/// Includes unit tests, load tests, and stress tests with assertions

const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const LOAD_TEST_DURATION_SECS = 10;
const RAMP_UP_SECS = 2;

pub const TestMode = enum {
    request_count, // Run until requests_per_client reached (original)
    duration, // Run for duration_seconds
    hybrid, // Run until EITHER limit reached
};

pub const TestConfig = struct {
    port: u16,
    num_clients: usize,

    // Test execution mode
    mode: TestMode,
    requests_per_client: usize, // Used in request_count/hybrid modes
    duration_seconds: ?u64, // Used in duration/hybrid modes

    message_type: u8,
    payload_size: usize,
    ramp_up: bool,

    // Progress reporting
    progress_interval_seconds: u64, // 0 = disabled
};

pub const TestResults = struct {
    total_requests: usize,
    successful_requests: usize,
    failed_requests: usize,
    total_duration_ms: i64,
    avg_latency_us: f64,
    p50_latency_us: u64,
    p95_latency_us: u64,
    p99_latency_us: u64,
    throughput_rps: f64,
    errors: std.ArrayList([]const u8),

    pub fn deinit(self: *TestResults, allocator: Allocator) void {
        for (self.errors.items) |err_msg| {
            allocator.free(err_msg);
        }
        self.errors.deinit(allocator);
    }
};

const ClientStats = struct {
    latencies_us: std.ArrayList(u64),
    successful: usize,
    failed: usize,
    mutex: Thread.Mutex,
    allocator: Allocator,

    fn init(allocator: Allocator) ClientStats {
        return .{
            .latencies_us = std.ArrayList(u64){},
            .successful = 0,
            .failed = 0,
            .mutex = Thread.Mutex{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *ClientStats) void {
        self.latencies_us.deinit(self.allocator);
    }

    fn recordSuccess(self: *ClientStats, latency_us: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.latencies_us.append(self.allocator, latency_us);
        self.successful += 1;
    }

    fn recordFailure(self: *ClientStats) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.failed += 1;
    }
};

const TestContext = struct {
    config: TestConfig,
    stats: *ClientStats,
    shutdown: std.atomic.Value(bool), // Coordinated shutdown
    start_time: i64, // For duration tracking
    allocator: Allocator,

    fn init(allocator: Allocator, config: TestConfig, stats: *ClientStats) TestContext {
        return .{
            .config = config,
            .stats = stats,
            .shutdown = std.atomic.Value(bool).init(false),
            .start_time = std.time.milliTimestamp(),
            .allocator = allocator,
        };
    }

    fn shouldStop(self: *TestContext, requests_sent: usize) bool {
        // Check shutdown flag (set by timer or manual interrupt)
        if (self.shutdown.load(.acquire)) {
            return true;
        }

        const elapsed_ms = std.time.milliTimestamp() - self.start_time;
        const elapsed_secs = @divTrunc(elapsed_ms, 1000);

        return switch (self.config.mode) {
            .request_count => requests_sent >= self.config.requests_per_client,
            .duration => if (self.config.duration_seconds) |dur|
                elapsed_secs >= dur
            else
                false,
            .hybrid => {
                const request_limit = requests_sent >= self.config.requests_per_client;
                const time_limit = if (self.config.duration_seconds) |dur|
                    elapsed_secs >= dur
                else
                    false;
                return request_limit or time_limit;
            },
        };
    }
};

pub fn runLoadTest(allocator: Allocator, config: TestConfig) !TestResults {
    std.log.info("=== Starting Load Test ===", .{});
    std.log.info("  Port: {}", .{config.port});
    std.log.info("  Clients: {}", .{config.num_clients});
    std.log.info("  Test mode: {s}", .{@tagName(config.mode)});
    if (config.mode == .request_count or config.mode == .hybrid) {
        std.log.info("  Requests per client: {}", .{config.requests_per_client});
        std.log.info("  Total requests: {}", .{config.num_clients * config.requests_per_client});
    }
    if (config.mode == .duration or config.mode == .hybrid) {
        if (config.duration_seconds) |dur| {
            std.log.info("  Duration limit: {}s", .{dur});
        }
    }
    std.log.info("  Message type: {}", .{config.message_type});
    std.log.info("  Payload size: {} bytes", .{config.payload_size});
    std.log.info("", .{});

    var stats = ClientStats.init(allocator);
    defer stats.deinit();

    var test_ctx = TestContext.init(allocator, config, &stats);

    const start_time = std.time.milliTimestamp();

    // Spawn client threads
    const threads = try allocator.alloc(Thread, config.num_clients);
    defer allocator.free(threads);

    for (threads, 0..) |*thread, i| {
        const ClientContext = struct {
            config: TestConfig,
            client_id: usize,
            test_ctx: *TestContext,
            allocator: Allocator,
        };

        const ctx = try allocator.create(ClientContext);
        ctx.* = .{
            .config = config,
            .client_id = i,
            .test_ctx = &test_ctx,
            .allocator = allocator,
        };

        thread.* = try Thread.spawn(.{}, struct {
            fn worker(context: *ClientContext) void {
                defer context.allocator.destroy(context);

                var requests_sent: usize = 0;

                // Check both request count and shutdown flag
                while (!context.test_ctx.shouldStop(requests_sent)) {
                    const start = std.time.microTimestamp();

                    sendRequest(
                        context.allocator,
                        context.config.port,
                        context.config.message_type,
                        context.config.payload_size,
                    ) catch {
                        context.test_ctx.stats.recordFailure();
                        requests_sent += 1;
                        continue;
                    };

                    const end = std.time.microTimestamp();
                    const latency_us: u64 = @intCast(end - start);

                    context.test_ctx.stats.recordSuccess(latency_us) catch {
                        std.log.err("Failed to record stats for client {}", .{context.client_id});
                    };

                    requests_sent += 1;

                    // Progress logging (less frequent than before)
                    if (requests_sent > 0 and requests_sent % 10000 == 0) {
                        std.log.debug("Client {} completed {} requests", .{
                            context.client_id,
                            requests_sent,
                        });
                    }
                }

                // Log final count for this client
                std.log.debug("Client {} finished with {} total requests", .{
                    context.client_id,
                    requests_sent,
                });
            }
        }.worker, .{ctx});

        // Ramp-up: stagger client starts
        if (config.ramp_up and i < config.num_clients - 1) {
            const delay_ms = (RAMP_UP_SECS * 1000) / config.num_clients;
            Thread.sleep(delay_ms * std.time.ns_per_ms);
        }
    }

    // Spawn timer thread for duration-based tests
    var timer_thread: ?Thread = null;
    if (config.mode == .duration or config.mode == .hybrid) {
        if (config.duration_seconds) |duration| {
            const TimerContext = struct {
                test_ctx: *TestContext,
                duration_secs: u64,
            };

            const timer_ctx = try allocator.create(TimerContext);
            timer_ctx.* = .{
                .test_ctx = &test_ctx,
                .duration_secs = duration,
            };

            timer_thread = try Thread.spawn(.{}, struct {
                fn timerWorker(ctx: *TimerContext) void {
                    defer ctx.test_ctx.allocator.destroy(ctx);

                    const duration_ns = ctx.duration_secs * std.time.ns_per_s;
                    Thread.sleep(duration_ns);

                    std.log.info("Duration limit ({d}s) reached, stopping test...", .{
                        ctx.duration_secs,
                    });
                    ctx.test_ctx.shutdown.store(true, .release);
                }
            }.timerWorker, .{timer_ctx});
        }
    }
    defer if (timer_thread) |t| t.join();

    // Spawn progress reporting thread
    var progress_thread: ?Thread = null;
    if (config.progress_interval_seconds > 0) {
        const ProgressContext = struct {
            test_ctx: *TestContext,
            interval_secs: u64,
        };

        const progress_ctx = try allocator.create(ProgressContext);
        progress_ctx.* = .{
            .test_ctx = &test_ctx,
            .interval_secs = config.progress_interval_seconds,
        };

        progress_thread = try Thread.spawn(.{}, struct {
            fn progressWorker(ctx: *ProgressContext) void {
                defer ctx.test_ctx.allocator.destroy(ctx);

                const interval_ns = ctx.interval_secs * std.time.ns_per_s;
                var last_successful: usize = 0;
                var last_time_ms = std.time.milliTimestamp();

                while (!ctx.test_ctx.shutdown.load(.acquire)) {
                    Thread.sleep(interval_ns);

                    ctx.test_ctx.stats.mutex.lock();
                    const current_successful = ctx.test_ctx.stats.successful;
                    const current_failed = ctx.test_ctx.stats.failed;
                    ctx.test_ctx.stats.mutex.unlock();

                    const now_ms = std.time.milliTimestamp();
                    const elapsed_total_secs = @divTrunc(
                        now_ms - ctx.test_ctx.start_time,
                        1000,
                    );
                    const elapsed_interval_ms = now_ms - last_time_ms;

                    const requests_in_interval = current_successful - last_successful;
                    const interval_throughput = @as(f64, @floatFromInt(requests_in_interval)) /
                        (@as(f64, @floatFromInt(elapsed_interval_ms)) / 1000.0);

                    std.log.info(
                        "[{d}s] Progress: {d} successful, {d} failed, {d:.1} req/s (interval)",
                        .{
                            elapsed_total_secs,
                            current_successful,
                            current_failed,
                            interval_throughput,
                        },
                    );

                    last_successful = current_successful;
                    last_time_ms = now_ms;
                }
            }
        }.progressWorker, .{progress_ctx});
    }
    defer if (progress_thread) |t| t.join();

    // Wait for all clients
    for (threads) |thread| {
        thread.join();
    }

    const end_time = std.time.milliTimestamp();
    const duration_ms = end_time - start_time;

    // Calculate statistics
    stats.mutex.lock();
    defer stats.mutex.unlock();

    const total_requests = stats.successful + stats.failed;
    std.mem.sort(u64, stats.latencies_us.items, {}, comptime std.sort.asc(u64));

    const avg_latency = if (stats.latencies_us.items.len > 0)
        calculateAverage(stats.latencies_us.items)
    else
        0.0;

    const p50 = if (stats.latencies_us.items.len > 0)
        percentile(stats.latencies_us.items, 50)
    else
        0;

    const p95 = if (stats.latencies_us.items.len > 0)
        percentile(stats.latencies_us.items, 95)
    else
        0;

    const p99 = if (stats.latencies_us.items.len > 0)
        percentile(stats.latencies_us.items, 99)
    else
        0;

    const throughput = @as(f64, @floatFromInt(total_requests)) /
        (@as(f64, @floatFromInt(duration_ms)) / 1000.0);

    return TestResults{
        .total_requests = total_requests,
        .successful_requests = stats.successful,
        .failed_requests = stats.failed,
        .total_duration_ms = duration_ms,
        .avg_latency_us = avg_latency,
        .p50_latency_us = p50,
        .p95_latency_us = p95,
        .p99_latency_us = p99,
        .throughput_rps = throughput,
        .errors = std.ArrayList([]const u8){},
    };
}

fn sendRequest(
    allocator: Allocator,
    port: u16,
    msg_type: u8,
    payload_size: usize,
) !void {
    // Explicit validation instead of assertions (won't be compiled out in release mode)
    if (payload_size > 4096) return error.PayloadTooLarge;
    if (msg_type == 0) return error.InvalidMessageType;

    const address = try net.Address.parseIp("127.0.0.1", port);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    // Prepare request
    var request_data: [4096]u8 = undefined;
    var request_len: usize = 0;

    switch (msg_type) {
        1 => { // Echo
            request_len = @min(payload_size, request_data.len);
            // Fill with pattern
            for (0..request_len) |i| {
                request_data[i] = @intCast(i % 256);
            }
        },
        2 => { // Ping
            const timestamp = std.time.milliTimestamp();
            std.mem.writeInt(i64, request_data[0..8], timestamp, .big);
            request_len = 8;
        },
        else => return error.UnknownMessageType,
    }

    // Send: [1 byte: type][4 bytes: length][N bytes: data]
    var header: [5]u8 = undefined;
    header[0] = msg_type;
    std.mem.writeInt(u32, header[1..5], @as(u32, @intCast(request_len)), .big);

    try stream.writeAll(&header);
    try stream.writeAll(request_data[0..request_len]);

    // Read response
    var response_header: [5]u8 = undefined;
    const header_read = try stream.read(&response_header);
    if (header_read < 5) return error.InvalidResponse;

    const response_len = std.mem.readInt(u32, response_header[1..5], .big);
    // Explicit validation to prevent buffer overflow
    if (response_len > 4096) return error.ResponseTooLarge;

    var response_data: [4096]u8 = undefined;
    const data_read = try stream.read(response_data[0..response_len]);
    if (data_read < response_len) return error.IncompleteResponse;

    // Verify echo (for type 1)
    if (msg_type == 1) {
        if (response_len != request_len) return error.LengthMismatch;
        if (!std.mem.eql(u8, request_data[0..request_len], response_data[0..response_len])) {
            return error.DataMismatch;
        }
    }

    _ = allocator; // Unused but needed for signature
}

fn calculateAverage(values: []const u64) f64 {
    var sum: u64 = 0;
    for (values) |v| {
        sum += v;
    }
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(values.len));
}

fn percentile(sorted_values: []const u64, p: u8) u64 {
    // Defensive programming: handle edge cases gracefully
    if (p == 0 or p > 100) return 0; // Invalid percentile
    if (sorted_values.len == 0) return 0; // Empty array

    const index = (@as(usize, p) * sorted_values.len) / 100;
    const clamped_index = @min(index, sorted_values.len - 1);
    return sorted_values[clamped_index];
}

pub fn printResults(results: TestResults, config: TestConfig) void {
    std.log.info("", .{});
    std.log.info("=== Load Test Results ===", .{});

    // Show test mode
    std.log.info("Test Mode:          {s}", .{@tagName(config.mode)});
    if (config.mode == .duration or config.mode == .hybrid) {
        if (config.duration_seconds) |dur| {
            std.log.info("Duration Limit:     {}s", .{dur});
        }
    }
    if (config.mode == .request_count or config.mode == .hybrid) {
        std.log.info("Request Limit:      {} per client", .{config.requests_per_client});
    }
    std.log.info("", .{});

    std.log.info("Total Requests:     {}", .{results.total_requests});
    std.log.info("Successful:         {} ({d:.1}%)", .{
        results.successful_requests,
        @as(f64, @floatFromInt(results.successful_requests)) * 100.0 /
            @as(f64, @floatFromInt(results.total_requests)),
    });
    std.log.info("Failed:             {} ({d:.1}%)", .{
        results.failed_requests,
        @as(f64, @floatFromInt(results.failed_requests)) * 100.0 /
            @as(f64, @floatFromInt(results.total_requests)),
    });
    std.log.info("Total Duration:     {}ms ({d:.2}s)", .{
        results.total_duration_ms,
        @as(f64, @floatFromInt(results.total_duration_ms)) / 1000.0,
    });
    std.log.info("", .{});
    std.log.info("Latency (microseconds):", .{});
    std.log.info("  Average:          {d:.1}µs", .{results.avg_latency_us});
    std.log.info("  P50:              {}µs", .{results.p50_latency_us});
    std.log.info("  P95:              {}µs", .{results.p95_latency_us});
    std.log.info("  P99:              {}µs", .{results.p99_latency_us});
    std.log.info("", .{});
    std.log.info("Throughput:         {d:.1} req/s", .{results.throughput_rps});
    std.log.info("", .{});
}

fn printUsage() void {
    std.log.info("Usage: test_harness <port> [clients] [requests] [flags]", .{});
    std.log.info("", .{});
    std.log.info("Positional arguments:", .{});
    std.log.info("  port        - Server port (default: 8080)", .{});
    std.log.info("  clients     - Number of concurrent clients (default: 10)", .{});
    std.log.info("  requests    - Requests per client (default: 1000)", .{});
    std.log.info("", .{});
    std.log.info("Optional flags:", .{});
    std.log.info("  --duration=N       - Run for N seconds (enables duration mode)", .{});
    std.log.info("  --requests=N       - Override requests per client", .{});
    std.log.info("  --progress=N       - Show progress every N seconds", .{});
    std.log.info("  --hybrid           - Use both duration and request limits", .{});
    std.log.info("  --single-test      - Run single test with exact CLI parameters (skip test suite)", .{});
    std.log.info("  --message-type=N   - Message type for single test (1=echo, 2=ping, default: 2)", .{});
    std.log.info("  --help             - Show this help message", .{});
    std.log.info("", .{});
    std.log.info("Examples:", .{});
    std.log.info("  test_harness 8080 50 10000", .{});
    std.log.info("    -> Run with 50 clients, 10K requests each", .{});
    std.log.info("", .{});
    std.log.info("  test_harness 8080 100 --duration=600 --progress=30", .{});
    std.log.info("    -> Run for 10 minutes with 100 clients, report every 30s", .{});
    std.log.info("", .{});
    std.log.info("  test_harness 8080 50 --duration=300 --requests=100000 --hybrid", .{});
    std.log.info("    -> Stop after 5 minutes OR 100K requests (whichever first)", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check for help flag
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        }
    }

    const port: u16 = if (args.len > 1)
        try std.fmt.parseInt(u16, args[1], 10)
    else
        8080;

    const num_clients: usize = if (args.len > 2)
        try std.fmt.parseInt(usize, args[2], 10)
    else
        10;

    // Support --duration flag
    var mode: TestMode = .request_count;
    var duration_seconds: ?u64 = null;
    var requests_per_client: usize = 1000;
    var progress_interval: u64 = 0;
    var single_test_mode: bool = false;
    var message_type_override: ?u8 = null;

    // Simple flag parsing
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--duration=")) {
            const value = arg["--duration=".len..];
            duration_seconds = try std.fmt.parseInt(u64, value, 10);
            mode = .duration;
        } else if (std.mem.startsWith(u8, arg, "--requests=")) {
            const value = arg["--requests=".len..];
            requests_per_client = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.startsWith(u8, arg, "--progress=")) {
            const value = arg["--progress=".len..];
            progress_interval = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--hybrid")) {
            mode = .hybrid;
        } else if (std.mem.eql(u8, arg, "--single-test")) {
            single_test_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--message-type=")) {
            const value = arg["--message-type=".len..];
            message_type_override = try std.fmt.parseInt(u8, value, 10);
        }
    }

    // Backward compatibility: use arg[3] if provided and no --requests flag
    if (args.len > 3 and requests_per_client == 1000) {
        const third_arg = args[3];
        // Only parse if it doesn't start with --
        if (!std.mem.startsWith(u8, third_arg, "--")) {
            requests_per_client = try std.fmt.parseInt(usize, third_arg, 10);
        }
    }

    if (!single_test_mode) {
        // Test 1: Light load - Echo
        {
            std.log.info("=== Test 1: Light Load (Echo) ===", .{});
            const test_config = TestConfig{
                .port = port,
                .num_clients = 5,
                .mode = .request_count,
                .requests_per_client = 100,
                .duration_seconds = null,
                .message_type = 1,
                .payload_size = 64,
                .ramp_up = false,
                .progress_interval_seconds = 0,
            };
            var results = try runLoadTest(allocator, test_config);
            defer results.deinit(allocator);
            printResults(results, test_config);
        }

        Thread.sleep(1 * std.time.ns_per_s);

        // Test 2: Medium load - Echo with larger payloads
        {
            std.log.info("=== Test 2: Medium Load (Larger Payloads) ===", .{});
            const test_config = TestConfig{
                .port = port,
                .num_clients = num_clients,
                .mode = .request_count,
                .requests_per_client = requests_per_client / 2,
                .duration_seconds = null,
                .message_type = 1,
                .payload_size = 1024,
                .ramp_up = true,
                .progress_interval_seconds = 0,
            };
            var results = try runLoadTest(allocator, test_config);
            defer results.deinit(allocator);
            printResults(results, test_config);
        }

        Thread.sleep(1 * std.time.ns_per_s);

        // Test 3: Heavy load - Many concurrent clients
        {
            std.log.info("=== Test 3: Heavy Load (Many Clients) ===", .{});
            const test_config = TestConfig{
                .port = port,
                .num_clients = num_clients * 2,
                .mode = .request_count,
                .requests_per_client = requests_per_client,
                .duration_seconds = null,
                .message_type = 1,
                .payload_size = 256,
                .ramp_up = true,
                .progress_interval_seconds = 0,
            };
            var results = try runLoadTest(allocator, test_config);
            defer results.deinit(allocator);
            printResults(results, test_config);
        }

        Thread.sleep(1 * std.time.ns_per_s);

        // Test 4: Ping/Pong stress test
        {
            std.log.info("=== Test 4: Ping/Pong Stress Test ===", .{});
            const test_config = TestConfig{
                .port = port,
                .num_clients = num_clients,
                .mode = .request_count,
                .requests_per_client = requests_per_client,
                .duration_seconds = null,
                .message_type = 2,
                .payload_size = 8,
                .ramp_up = false,
                .progress_interval_seconds = 0,
            };
            var results = try runLoadTest(allocator, test_config);
            defer results.deinit(allocator);
            printResults(results, test_config);
        }

        Thread.sleep(1 * std.time.ns_per_s);

        // Test 5: Duration-based sustained load (if duration mode enabled)
        if (mode == .duration or mode == .hybrid) {
            std.log.info("=== Test 5: Sustained Load (Duration-Based) ===", .{});
            const test_config = TestConfig{
                .port = port,
                .num_clients = num_clients,
                .mode = .duration,
                .requests_per_client = 0, // Ignored in duration mode
                .duration_seconds = if (duration_seconds) |d| d else 60, // Default 60s
                .message_type = 1,
                .payload_size = 512,
                .ramp_up = true,
                .progress_interval_seconds = progress_interval,
            };
            var results = try runLoadTest(allocator, test_config);
            defer results.deinit(allocator);
            printResults(results, test_config);
        }
    } else {
        // Single test mode: run exactly one test with CLI parameters
        const msg_type = message_type_override orelse 2;
        const test_config = TestConfig{
            .port = port,
            .num_clients = num_clients,
            .mode = mode,
            .requests_per_client = requests_per_client,
            .duration_seconds = duration_seconds,
            .message_type = msg_type,
            .payload_size = if (msg_type == 2) 8 else 64,
            .ramp_up = false,
            .progress_interval_seconds = progress_interval,
        };
        var results = try runLoadTest(allocator, test_config);
        defer results.deinit(allocator);
        printResults(results, test_config);
    }

    std.log.info("", .{});
    std.log.info("=== All Tests Complete ===", .{});
}

// Unit tests
test "percentile calculation" {
    var values = [_]u64{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    try std.testing.expectEqual(@as(u64, 50), percentile(&values, 50));
    try std.testing.expectEqual(@as(u64, 90), percentile(&values, 90));
    try std.testing.expectEqual(@as(u64, 100), percentile(&values, 100));
}

test "average calculation" {
    const values = [_]u64{ 10, 20, 30, 40, 50 };
    try std.testing.expectEqual(@as(f64, 30.0), calculateAverage(&values));
}

test "duration mode shutdown" {
    const allocator = std.testing.allocator;
    var stats = ClientStats.init(allocator);
    defer stats.deinit();

    var ctx = TestContext.init(allocator, .{
        .port = 8080,
        .num_clients = 1,
        .mode = .duration,
        .requests_per_client = 1000000, // Unreachable
        .duration_seconds = 1, // 1 second
        .message_type = 1,
        .payload_size = 64,
        .ramp_up = false,
        .progress_interval_seconds = 0,
    }, &stats);

    // Simulate time passing
    Thread.sleep(1100 * std.time.ns_per_ms);

    try std.testing.expect(ctx.shouldStop(0));
}

test "request count mode shutdown" {
    const allocator = std.testing.allocator;
    var stats = ClientStats.init(allocator);
    defer stats.deinit();

    var ctx = TestContext.init(allocator, .{
        .port = 8080,
        .num_clients = 1,
        .mode = .request_count,
        .requests_per_client = 100,
        .duration_seconds = null,
        .message_type = 1,
        .payload_size = 64,
        .ramp_up = false,
        .progress_interval_seconds = 0,
    }, &stats);

    try std.testing.expect(!ctx.shouldStop(99));
    try std.testing.expect(ctx.shouldStop(100));
}

test "hybrid mode shutdown - request limit" {
    const allocator = std.testing.allocator;
    var stats = ClientStats.init(allocator);
    defer stats.deinit();

    var ctx = TestContext.init(allocator, .{
        .port = 8080,
        .num_clients = 1,
        .mode = .hybrid,
        .requests_per_client = 1000,
        .duration_seconds = 60,
        .message_type = 1,
        .payload_size = 64,
        .ramp_up = false,
        .progress_interval_seconds = 0,
    }, &stats);

    // Should stop when request limit reached (before duration)
    try std.testing.expect(ctx.shouldStop(1000));
}
