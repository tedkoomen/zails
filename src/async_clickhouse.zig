/// Async ClickHouse Writer with Lock-Free Ring Buffer
/// Non-blocking metric recording with background batch flushing
/// Tiger Style: NEVER THROWS - all errors are values

const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const ClickHouseClient = @import("clickhouse_client.zig").ClickHouseClient;

/// Metric row structure for ClickHouse
pub const MetricRow = struct {
    timestamp: i64,
    request_id: [16]u8, // UUID
    message_type: u8,
    handler_name: [64]u8,
    latency_us: u64,
    request_size: u32,
    response_size: u32,
    client_ip: u32,
    client_port: u16,
    worker_id: u16,
    error_code: u8,
    error_message: [256]u8,
    server_instance: [64]u8,
    request_sample: [256]u8,
    response_sample: [256]u8,
    capture_payload: bool,

    /// Escape a string for JSON (handle quotes, backslashes, control chars)
    fn jsonEscapeSlice(output: []u8, pos: *usize, input: []const u8) void {
        for (input) |c| {
            if (pos.* + 2 > output.len) break;
            switch (c) {
                '"' => {
                    output[pos.*] = '\\';
                    pos.* += 1;
                    output[pos.*] = '"';
                    pos.* += 1;
                },
                '\\' => {
                    output[pos.*] = '\\';
                    pos.* += 1;
                    output[pos.*] = '\\';
                    pos.* += 1;
                },
                '\n' => {
                    output[pos.*] = '\\';
                    pos.* += 1;
                    output[pos.*] = 'n';
                    pos.* += 1;
                },
                '\r' => {
                    output[pos.*] = '\\';
                    pos.* += 1;
                    output[pos.*] = 'r';
                    pos.* += 1;
                },
                '\t' => {
                    output[pos.*] = '\\';
                    pos.* += 1;
                    output[pos.*] = 't';
                    pos.* += 1;
                },
                else => {
                    if (c < 0x20) continue; // Skip other control characters
                    output[pos.*] = c;
                    pos.* += 1;
                },
            }
        }
    }

    /// Convert to JSON string for JSONEachRow format
    pub fn toJSON(self: *const MetricRow, allocator: Allocator) ![]u8 {
        // Convert UUID to hex string (fixed 36-byte format: 8-4-4-4-12)
        var uuid_hex: [36]u8 = undefined;
        // UUID format is guaranteed to fit in 36 bytes
        _ = std.fmt.bufPrint(&uuid_hex, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            self.request_id[0],  self.request_id[1],  self.request_id[2],  self.request_id[3],
            self.request_id[4],  self.request_id[5],  self.request_id[6],  self.request_id[7],
            self.request_id[8],  self.request_id[9],  self.request_id[10], self.request_id[11],
            self.request_id[12], self.request_id[13], self.request_id[14], self.request_id[15],
        }) catch |err| {
            // Should never happen with fixed UUID format
            std.log.err("UUID formatting failed: {}", .{err});
            @memcpy(&uuid_hex, "00000000-0000-0000-0000-000000000000");
        };

        // Find null terminators for strings
        const handler_name_len = std.mem.indexOfScalar(u8, &self.handler_name, 0) orelse self.handler_name.len;
        const error_msg_len = std.mem.indexOfScalar(u8, &self.error_message, 0) orelse self.error_message.len;
        const server_instance_len = std.mem.indexOfScalar(u8, &self.server_instance, 0) orelse self.server_instance.len;

        // Build JSON manually with escaping (max 4KB per row to handle escaping expansion)
        var buffer = try allocator.alloc(u8, 4096);
        errdefer allocator.free(buffer);

        // Write fixed numeric prefix
        const prefix = try std.fmt.bufPrint(
            buffer,
            \\{{"timestamp":{d},"request_id":"{s}","message_type":{d},"handler_name":"
        ,
            .{ self.timestamp, uuid_hex, self.message_type },
        );
        var total_len = prefix.len;

        // Escape handler_name
        jsonEscapeSlice(buffer, &total_len, self.handler_name[0..handler_name_len]);

        // Write numeric fields
        const mid = std.fmt.bufPrint(
            buffer[total_len..],
            \\","latency_us":{d},"request_size":{d},"response_size":{d},"client_ip":{d},"client_port":{d},"worker_id":{d},"error_code":{d},"error_message":"
        ,
            .{
                self.latency_us, self.request_size, self.response_size,
                self.client_ip,  self.client_port,  self.worker_id,
                self.error_code,
            },
        ) catch return error.NoSpaceLeft;
        total_len += mid.len;

        // Escape error_message
        jsonEscapeSlice(buffer, &total_len, self.error_message[0..error_msg_len]);

        // server_instance
        const si_prefix = std.fmt.bufPrint(buffer[total_len..],
            \\","server_instance":"
        , .{}) catch return error.NoSpaceLeft;
        total_len += si_prefix.len;
        jsonEscapeSlice(buffer, &total_len, self.server_instance[0..server_instance_len]);

        // Payload samples
        if (self.capture_payload) {
            const request_sample_len = std.mem.indexOfScalar(u8, &self.request_sample, 0) orelse self.request_sample.len;
            const response_sample_len = std.mem.indexOfScalar(u8, &self.response_sample, 0) orelse self.response_sample.len;

            const rs_prefix = std.fmt.bufPrint(buffer[total_len..],
                \\","request_sample":"
            , .{}) catch return error.NoSpaceLeft;
            total_len += rs_prefix.len;
            jsonEscapeSlice(buffer, &total_len, self.request_sample[0..request_sample_len]);

            const rsp_prefix = std.fmt.bufPrint(buffer[total_len..],
                \\","response_sample":"
            , .{}) catch return error.NoSpaceLeft;
            total_len += rsp_prefix.len;
            jsonEscapeSlice(buffer, &total_len, self.response_sample[0..response_sample_len]);

            if (total_len + 2 > buffer.len) return error.NoSpaceLeft;
            buffer[total_len] = '"';
            total_len += 1;
            buffer[total_len] = '}';
            total_len += 1;
        } else {
            const end_json = "\",\"request_sample\":\"\",\"response_sample\":\"\"}";
            if (total_len + end_json.len > buffer.len) return error.NoSpaceLeft;
            @memcpy(buffer[total_len .. total_len + end_json.len], end_json);
            total_len += end_json.len;
        }

        // Shrink allocation to actual size so callers can free correctly
        // On realloc failure, return the full-sized buffer (caller frees with correct length)
        if (total_len < buffer.len) {
            return allocator.realloc(buffer, total_len) catch buffer;
        }
        return buffer;
    }
};

/// Lock-free ring buffer for metrics (MPMC-safe)
/// Uses per-slot sequence numbers to ensure data is fully written before
/// consumers can read it, and to allow multiple producers/consumers.
const RingBuffer = struct {
    items: []MetricRow,
    sequences: []std.atomic.Value(usize),
    head: std.atomic.Value(usize),
    tail: std.atomic.Value(usize),
    capacity: usize,

    fn init(allocator: Allocator, capacity: usize) !RingBuffer {
        const items = try allocator.alloc(MetricRow, capacity);
        errdefer allocator.free(items);

        const sequences = try allocator.alloc(std.atomic.Value(usize), capacity);
        // Initialize each sequence to its index (slot is "ready for writing at this round")
        for (sequences, 0..) |*seq, i| {
            seq.* = std.atomic.Value(usize).init(i);
        }

        return RingBuffer{
            .items = items,
            .sequences = sequences,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
            .capacity = capacity,
        };
    }

    fn deinit(self: *RingBuffer, allocator: Allocator) void {
        allocator.free(self.sequences);
        allocator.free(self.items);
    }

    fn push(self: *RingBuffer, metric: MetricRow) bool {
        while (true) {
            const head = self.head.load(.acquire);
            const idx = head % self.capacity;
            const seq = self.sequences[idx].load(.acquire);

            // If sequence == head, the slot is available for writing
            if (seq == head) {
                // Try to claim this slot
                if (self.head.cmpxchgWeak(head, head + 1, .acq_rel, .acquire)) |_| {
                    continue; // Another producer claimed it, retry
                }
                // We own slot `idx` — write data
                self.items[idx] = metric;
                // Signal that data is ready for consumers (sequence = head + 1)
                self.sequences[idx].store(head + 1, .release);
                return true;
            } else if (seq < head) {
                // Slot not yet consumed — buffer is full
                return false;
            }
            // seq > head means another producer is in progress, spin
        }
    }

    fn pop(self: *RingBuffer) ?MetricRow {
        while (true) {
            const tail = self.tail.load(.acquire);
            const idx = tail % self.capacity;
            const seq = self.sequences[idx].load(.acquire);

            // If sequence == tail + 1, data has been written and is ready
            if (seq == tail + 1) {
                // Try to claim this slot for consumption
                if (self.tail.cmpxchgWeak(tail, tail + 1, .acq_rel, .acquire)) |_| {
                    continue; // Another consumer claimed it, retry
                }
                const metric = self.items[idx];
                // Mark slot as available for the next round of writing
                // Next valid head for this slot = tail + capacity
                self.sequences[idx].store(tail + self.capacity, .release);
                return metric;
            } else if (seq < tail + 1) {
                // Data not yet written — buffer empty or producer in progress
                return null;
            }
            // seq > tail + 1 shouldn't happen, but spin just in case
        }
    }

    fn size(self: *RingBuffer) usize {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        if (head >= tail) {
            return head - tail;
        }
        return 0; // Shouldn't happen with monotonic head/tail
    }
};

/// Configuration for async writer
pub const AsyncWriterConfig = struct {
    batch_size: usize,
    flush_interval_seconds: u64,
    buffer_capacity: usize,
    table_name: []const u8,
};

/// Async ClickHouse writer with background flushing
pub const AsyncClickHouseWriter = struct {
    thread: Thread,
    shutdown: std.atomic.Value(bool),
    buffer: RingBuffer,
    client: *ClickHouseClient,
    config: AsyncWriterConfig,
    allocator: Allocator,
    total_written: std.atomic.Value(u64),
    total_dropped: std.atomic.Value(u64),

    pub fn init(
        allocator: Allocator,
        client: *ClickHouseClient,
        config: AsyncWriterConfig,
    ) !*AsyncClickHouseWriter {
        const self = try allocator.create(AsyncClickHouseWriter);
        errdefer allocator.destroy(self);

        self.* = AsyncClickHouseWriter{
            .thread = undefined,
            .shutdown = std.atomic.Value(bool).init(false),
            .buffer = try RingBuffer.init(allocator, config.buffer_capacity),
            .client = client,
            .config = config,
            .allocator = allocator,
            .total_written = std.atomic.Value(u64).init(0),
            .total_dropped = std.atomic.Value(u64).init(0),
        };

        self.thread = try Thread.spawn(.{}, writerThread, .{self});

        std.log.info("AsyncClickHouseWriter started (batch_size={d}, buffer_capacity={d})", .{
            config.batch_size,
            config.buffer_capacity,
        });

        return self;
    }

    pub fn deinit(self: *AsyncClickHouseWriter) void {
        std.log.info("Shutting down AsyncClickHouseWriter...", .{});
        self.shutdown.store(true, .release);
        self.thread.join();

        std.log.info("AsyncClickHouseWriter stats: written={d}, dropped={d}", .{
            self.total_written.load(.acquire),
            self.total_dropped.load(.acquire),
        });

        // Copy allocator before destroying self to avoid use-after-free
        const alloc = self.allocator;
        self.buffer.deinit(alloc);
        alloc.destroy(self);
    }

    /// Non-blocking metric recording - drops if buffer is full
    pub fn recordMetric(self: *AsyncClickHouseWriter, metric: MetricRow) void {
        if (!self.buffer.push(metric)) {
            const dropped_count = self.total_dropped.fetchAdd(1, .monotonic);
            // Log warning every 1000 dropped metrics to avoid log spam
            if (dropped_count % 1000 == 0) {
                std.log.warn("ClickHouse ring buffer full - dropped {} total metrics (buffer capacity: {})", .{
                    dropped_count + 1,
                    self.config.buffer_capacity,
                });
            }
        }
    }

    /// Background writer thread
    fn writerThread(self: *AsyncClickHouseWriter) void {
        std.log.info("ClickHouse writer thread started", .{});

        const flush_interval_ns = self.config.flush_interval_seconds * std.time.ns_per_s;
        var batch = self.allocator.alloc(MetricRow, self.config.batch_size) catch |err| {
            std.log.err("Failed to allocate batch buffer: {}", .{err});
            return;
        };
        defer self.allocator.free(batch);

        while (!self.shutdown.load(.acquire)) {
            // Sleep for flush interval
            Thread.sleep(flush_interval_ns);

            // Collect batch from ring buffer
            var count: usize = 0;
            while (count < self.config.batch_size) {
                if (self.buffer.pop()) |metric| {
                    batch[count] = metric;
                    count += 1;
                } else {
                    break; // No more metrics
                }
            }

            if (count > 0) {
                self.flushBatch(batch[0..count]);
            }
        }

        // Final flush on shutdown — drain ALL remaining metrics
        std.log.info("Final flush before shutdown...", .{});
        while (true) {
            var count: usize = 0;
            while (count < self.config.batch_size) {
                if (self.buffer.pop()) |metric| {
                    batch[count] = metric;
                    count += 1;
                } else {
                    break;
                }
            }
            if (count > 0) {
                self.flushBatch(batch[0..count]);
            }
            if (count < self.config.batch_size) break; // Buffer is drained
        }

        std.log.info("ClickHouse writer thread stopped", .{});
    }

    /// Flush batch to ClickHouse
    fn flushBatch(self: *AsyncClickHouseWriter, metrics: []MetricRow) void {
        // Use larger estimate to prevent truncation (2KB per metric to be safe)
        const estimated_size = metrics.len * 2048;
        var buffer = self.allocator.alloc(u8, estimated_size) catch {
            std.log.err("Failed to allocate buffer for batch of {} metrics", .{metrics.len});
            return;
        };
        defer self.allocator.free(buffer);

        var pos: usize = 0;
        var written_count: usize = 0;

        for (metrics) |*metric| {
            const row_json = metric.toJSON(self.allocator) catch |err| {
                std.log.err("Failed to serialize metric to JSON: {}", .{err});
                continue;
            };
            defer self.allocator.free(row_json);

            // Check if we have space for this metric + newline
            if (pos + row_json.len + 1 > buffer.len) {
                std.log.err("Buffer overflow prevented: need {} bytes but only {} available. Skipping remaining metrics.", .{
                    pos + row_json.len + 1,
                    buffer.len,
                });
                break;
            }

            @memcpy(buffer[pos .. pos + row_json.len], row_json);
            pos += row_json.len;
            buffer[pos] = '\n';
            pos += 1;
            written_count += 1;
        }

        if (written_count < metrics.len) {
            std.log.warn("Only wrote {} of {} metrics during batch flush", .{ written_count, metrics.len });
        }

        // Insert batch
        const actually_written = written_count;
        const insert_result = self.client.insertBatch(self.config.table_name, buffer[0..pos]);
        if (insert_result.isOk()) {
            _ = self.total_written.fetchAdd(actually_written, .monotonic);
            std.log.debug("Flushed {d} metrics to ClickHouse", .{actually_written});
        } else {
            std.log.err("Failed to flush metrics to ClickHouse: {}", .{insert_result.err});
        }
    }

    /// Get statistics
    pub fn getStats(self: *AsyncClickHouseWriter) Stats {
        return Stats{
            .written = self.total_written.load(.acquire),
            .dropped = self.total_dropped.load(.acquire),
            .buffered = self.buffer.size(),
        };
    }

    pub const Stats = struct {
        written: u64,
        dropped: u64,
        buffered: usize,
    };
};

// Tests
test "MetricRow JSON serialization" {
    const allocator = std.testing.allocator;

    var metric = MetricRow{
        .timestamp = 1234567890,
        .request_id = [_]u8{0} ** 16,
        .message_type = 1,
        .handler_name = [_]u8{0} ** 64,
        .latency_us = 1000,
        .request_size = 100,
        .response_size = 200,
        .client_ip = 16777343, // 127.0.0.1
        .client_port = 8080,
        .worker_id = 1,
        .error_code = 0,
        .error_message = [_]u8{0} ** 256,
        .server_instance = [_]u8{0} ** 64,
        .request_sample = [_]u8{0} ** 256,
        .response_sample = [_]u8{0} ** 256,
        .capture_payload = false,
    };

    @memcpy(metric.handler_name[0.."echo_handler".len], "echo_handler");
    @memcpy(metric.server_instance[0.."server-1".len], "server-1");

    const json = try metric.toJSON(allocator);
    defer allocator.free(json);

    try std.testing.expect(json.len > 0);
}
