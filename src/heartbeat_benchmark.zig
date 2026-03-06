/// Heartbeat (Ping) Performance Benchmark
const std = @import("std");
const net = std.net;

const BenchmarkResults = struct {
    total_requests: usize,
    successful_requests: usize,
    failed_requests: usize,
    total_duration_ns: i128,
    min_latency_us: u64,
    max_latency_us: u64,
    avg_latency_us: f64,
    p50_latency_us: u64,
    p95_latency_us: u64,
    p99_latency_us: u64,
    throughput_rps: f64,
};

fn sendPingRequest(port: u16) !u64 {
    const address = try net.Address.parseIp("127.0.0.1", port);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    const start = std.time.nanoTimestamp();

    // Prepare ping request
    const timestamp = std.time.milliTimestamp();
    var request_data: [8]u8 = undefined;
    std.mem.writeInt(i64, &request_data, timestamp, .big);

    // Send: [1 byte: type=2][4 bytes: length=8][8 bytes: timestamp]
    var header: [5]u8 = undefined;
    header[0] = 2; // Ping message type
    std.mem.writeInt(u32, header[1..5], 8, .big);

    try stream.writeAll(&header);
    try stream.writeAll(&request_data);

    // Read response header
    var response_header: [5]u8 = undefined;
    const header_read = try stream.read(&response_header);
    if (header_read < 5) return error.InvalidResponse;

    const response_len = std.mem.readInt(u32, response_header[1..5], .big);
    if (response_len != 24) return error.InvalidPingResponse;

    // Read response data (24 bytes: request_ts + server_ts + uptime)
    var response_data: [24]u8 = undefined;
    const data_read = try stream.read(&response_data);
    if (data_read < 24) return error.IncompleteResponse;

    const end = std.time.nanoTimestamp();
    const latency_us: u64 = @intCast(@divTrunc(end - start, 1000));

    return latency_us;
}

fn runBenchmark(allocator: std.mem.Allocator, port: u16, num_requests: usize) !BenchmarkResults {
    std.debug.print("Running heartbeat benchmark...\n", .{});
    std.debug.print("  Port: {}\n", .{port});
    std.debug.print("  Requests: {}\n\n", .{num_requests});

    var latencies = try allocator.alloc(u64, num_requests);
    defer allocator.free(latencies);

    var successful: usize = 0;
    var failed: usize = 0;
    var min_latency: u64 = std.math.maxInt(u64);
    var max_latency: u64 = 0;
    var total_latency: u64 = 0;

    const overall_start = std.time.nanoTimestamp();

    for (0..num_requests) |i| {
        if (sendPingRequest(port)) |latency_us| {
            latencies[successful] = latency_us;
            successful += 1;
            total_latency += latency_us;
            min_latency = @min(min_latency, latency_us);
            max_latency = @max(max_latency, latency_us);

            if ((i + 1) % 1000 == 0) {
                std.debug.print("  Progress: {}/{}\r", .{ i + 1, num_requests });
            }
        } else |_| {
            failed += 1;
        }
    }

    const overall_end = std.time.nanoTimestamp();
    const total_duration_ns = overall_end - overall_start;

    std.debug.print("\n\n", .{});

    if (successful == 0) {
        return error.AllRequestsFailed;
    }

    // Calculate percentiles
    std.mem.sort(u64, latencies[0..successful], {}, comptime std.sort.asc(u64));

    const p50_idx = successful / 2;
    const p95_idx = (successful * 95) / 100;
    const p99_idx = (successful * 99) / 100;

    const avg_latency: f64 = @as(f64, @floatFromInt(total_latency)) / @as(f64, @floatFromInt(successful));
    const duration_s: f64 = @as(f64, @floatFromInt(total_duration_ns)) / 1_000_000_000.0;
    const throughput: f64 = @as(f64, @floatFromInt(successful)) / duration_s;

    return BenchmarkResults{
        .total_requests = num_requests,
        .successful_requests = successful,
        .failed_requests = failed,
        .total_duration_ns = total_duration_ns,
        .min_latency_us = min_latency,
        .max_latency_us = max_latency,
        .avg_latency_us = avg_latency,
        .p50_latency_us = latencies[p50_idx],
        .p95_latency_us = latencies[p95_idx],
        .p99_latency_us = latencies[p99_idx],
        .throughput_rps = throughput,
    };
}

fn printResults(results: BenchmarkResults) void {
    std.debug.print("=== Heartbeat Performance Results ===\n\n", .{});

    std.debug.print("Requests:\n", .{});
    std.debug.print("  Total:      {}\n", .{results.total_requests});
    std.debug.print("  Successful: {} ({d:.1}%)\n", .{
        results.successful_requests,
        @as(f64, @floatFromInt(results.successful_requests)) * 100.0 / @as(f64, @floatFromInt(results.total_requests)),
    });
    std.debug.print("  Failed:     {} ({d:.1}%)\n\n", .{
        results.failed_requests,
        @as(f64, @floatFromInt(results.failed_requests)) * 100.0 / @as(f64, @floatFromInt(results.total_requests)),
    });

    const duration_ms: f64 = @as(f64, @floatFromInt(results.total_duration_ns)) / 1_000_000.0;
    std.debug.print("Duration:     {d:.2}ms ({d:.2}s)\n\n", .{ duration_ms, duration_ms / 1000.0 });

    std.debug.print("Latency (microseconds):\n", .{});
    std.debug.print("  Min:     {}µs\n", .{results.min_latency_us});
    std.debug.print("  Average: {d:.1}µs\n", .{results.avg_latency_us});
    std.debug.print("  P50:     {}µs\n", .{results.p50_latency_us});
    std.debug.print("  P95:     {}µs\n", .{results.p95_latency_us});
    std.debug.print("  P99:     {}µs\n", .{results.p99_latency_us});
    std.debug.print("  Max:     {}µs\n\n", .{results.max_latency_us});

    std.debug.print("Throughput:   {d:.1} req/s\n\n", .{results.throughput_rps});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <port> [num_requests]\n", .{args[0]});
        std.debug.print("Example: {s} 8080 5000\n", .{args[0]});
        return;
    }

    const port = try std.fmt.parseInt(u16, args[1], 10);
    const num_requests: usize = if (args.len >= 3)
        try std.fmt.parseInt(usize, args[2], 10)
    else
        1000;

    const results = try runBenchmark(allocator, port, num_requests);
    printResults(results);
}
