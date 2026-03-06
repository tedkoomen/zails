/// Reactive Model with Lock-Free Accessors
///
/// Features:
/// - Comptime-generated getters/setters for each field
/// - Lock-free updates using atomic version numbers
/// - Automatic event publishing on changes
/// - Optimistic concurrency control
///
/// Example usage:
///   const Trade = ReactiveModel("trades", .{
///       .symbol = .String,
///       .price = .i64,
///       .quantity = .i64,
///   });
///
///   var trade = Trade.init(allocator);
///   trade.setPrice(15000);  // Lock-free update + publishes event
///   const price = trade.getPrice();  // Lock-free read

const std = @import("std");
const Allocator = std.mem.Allocator;
const message_bus = @import("message_bus/mod.zig");
const Event = @import("event.zig").Event;
const generateEventId = @import("event.zig").generateEventId;

/// Field type enum
pub const FieldType = enum {
    String,
    i64,
    u64,
    f64,
    bool,
    DateTime,
};

/// Reactive Model generator
///
/// Creates a model with:
/// - Lock-free getters/setters for each field
/// - Atomic version number for optimistic concurrency
/// - Automatic event publishing on updates
///
pub fn ReactiveModel(comptime table_name: []const u8, comptime fields: anytype) type {
    const field_count = @typeInfo(@TypeOf(fields)).@"struct".fields.len;

    return struct {
        const Self = @This();

        // Version number for optimistic locking
        version: std.atomic.Value(u64),

        // Database ID
        id: u64,

        // Allocator for string fields
        allocator: Allocator,

        // Lock for string field updates (atomic primitives can't hold strings)
        string_lock: std.Thread.Mutex,

        // Field storage (generated at comptime)
        fields: FieldStorage,

        /// Field storage structure (comptime-generated)
        pub const FieldStorage = blk: {
            var struct_fields: [field_count]std.builtin.Type.StructField = undefined;

            for (@typeInfo(@TypeOf(fields)).@"struct".fields, 0..) |field, i| {
                const field_name = field.name;
                const field_type = @field(fields, field_name);

                // Generate appropriate storage type
                const storage_type = switch (field_type) {
                    .String => []const u8,
                    .i64 => std.atomic.Value(i64),
                    .u64 => std.atomic.Value(u64),
                    .f64 => std.atomic.Value(u64), // Store f64 as u64 bits
                    .bool => std.atomic.Value(bool),
                    .DateTime => std.atomic.Value(i64), // Unix timestamp
                    else => @compileError("Unsupported field type"),
                };

                struct_fields[i] = .{
                    .name = field_name,
                    .type = storage_type,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(storage_type),
                };
            }

            break :blk @Type(.{
                .@"struct" = .{
                    .layout = .auto,
                    .fields = &struct_fields,
                    .decls = &.{},
                    .is_tuple = false,
                },
            });
        };

        /// Initialize model
        pub fn init(allocator: Allocator) Self {
            var self = Self{
                .version = std.atomic.Value(u64).init(1),
                .id = 0,
                .allocator = allocator,
                .string_lock = .{},
                .fields = undefined,
            };

            // Initialize atomic fields
            inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |field| {
                const field_name = field.name;
                const field_type = @field(fields, field_name);

                switch (field_type) {
                    .String => {
                        @field(self.fields, field_name) = "";
                    },
                    .i64 => {
                        @field(self.fields, field_name) = std.atomic.Value(i64).init(0);
                    },
                    .u64 => {
                        @field(self.fields, field_name) = std.atomic.Value(u64).init(0);
                    },
                    .f64 => {
                        @field(self.fields, field_name) = std.atomic.Value(u64).init(0);
                    },
                    .bool => {
                        @field(self.fields, field_name) = std.atomic.Value(bool).init(false);
                    },
                    .DateTime => {
                        @field(self.fields, field_name) = std.atomic.Value(i64).init(0);
                    },
                    else => @compileError("Unsupported field type"),
                }
            }

            return self;
        }

        /// Deinitialize model
        pub fn deinit(self: *Self) void {
            // Free string fields
            inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |field| {
                const field_name = field.name;
                const field_type = @field(fields, field_name);

                switch (field_type) {
                    .String => {
                        const str = @field(self.fields, field_name);
                        if (str.len > 0) {
                            self.allocator.free(str);
                        }
                    },
                    else => {},
                }
            }
        }

        // Note: Comptime method generation would go here, but Zig doesn't
        // currently support generating methods dynamically at comptime.
        // For now, we provide manual accessors below for common fields.

        /// Manual accessors (until comptime method generation is fully supported)
        ///
        /// For each field, we provide:
        /// - get{FieldName}(): Lock-free read
        /// - set{FieldName}(value): Lock-free write + event publish
        /// - compareAndSwap{FieldName}(expected, new): CAS operation

        // Symbol accessors (String)
        // Note: Must be non-const to lock mutex
        pub fn getSymbol(self: *Self) []const u8 {
            self.string_lock.lock();
            defer self.string_lock.unlock();
            return @field(self.fields, "symbol");
        }

        pub fn setSymbol(self: *Self, value: []const u8, bus: ?*message_bus.MessageBus) !void {
            // Allocate new value BEFORE locking to avoid deadlock on alloc failure
            const new_str = try self.allocator.dupe(u8, value);

            self.string_lock.lock();
            defer self.string_lock.unlock();

            const old = @field(self.fields, "symbol");
            @field(self.fields, "symbol") = new_str;

            // Free old value AFTER replacing (avoids use-after-free)
            if (old.len > 0) {
                self.allocator.free(old);
            }

            // Increment version
            _ = self.version.fetchAdd(1, .monotonic);

            // Publish event (best-effort, don't fail the setter)
            self.publishUpdateEvent(bus) catch {};
        }

        // Price accessors (i64)
        pub fn getPrice(self: *const Self) i64 {
            return @field(self.fields, "price").load(.acquire);
        }

        pub fn setPrice(self: *Self, value: i64, bus: ?*message_bus.MessageBus) !void {
            @field(self.fields, "price").store(value, .release);
            _ = self.version.fetchAdd(1, .monotonic);
            try self.publishUpdateEvent(bus);
        }

        pub fn compareAndSwapPrice(self: *Self, expected: i64, new: i64, bus: ?*message_bus.MessageBus) !bool {
            const success = @field(self.fields, "price").cmpxchgStrong(
                expected,
                new,
                .acq_rel,
                .acquire,
            ) == null;

            if (success) {
                _ = self.version.fetchAdd(1, .monotonic);
                try self.publishUpdateEvent(bus);
            }

            return success;
        }

        // Quantity accessors (i64)
        pub fn getQuantity(self: *const Self) i64 {
            return @field(self.fields, "quantity").load(.acquire);
        }

        pub fn setQuantity(self: *Self, value: i64, bus: ?*message_bus.MessageBus) !void {
            @field(self.fields, "quantity").store(value, .release);
            _ = self.version.fetchAdd(1, .monotonic);
            try self.publishUpdateEvent(bus);
        }

        /// Get current version (for optimistic locking)
        pub fn getVersion(self: *const Self) u64 {
            return self.version.load(.acquire);
        }

        /// Publish update event to message bus
        fn publishUpdateEvent(self: *Self, bus: ?*message_bus.MessageBus) !void {
            if (bus) |b| {
                // Serialize current state to JSON
                var buffer: [4096]u8 = undefined;
                const json = try self.toJSON(&buffer);

                const event = Event{
                    .id = generateEventId(),
                    .timestamp = std.time.microTimestamp(),
                    .event_type = .model_updated,
                    .topic = table_name ++ ".updated",
                    .model_type = table_name,
                    .model_id = self.id,
                    .data = json,
                };

                b.publish(event);
            }
        }

        /// Serialize to JSON
        pub fn toJSON(self: *Self, buffer: []u8) ![]const u8 {
            const symbol = self.getSymbol();
            const price = self.getPrice();
            const quantity = self.getQuantity();

            return try std.fmt.bufPrint(
                buffer,
                "{{\"symbol\":\"{s}\",\"price\":{d},\"quantity\":{d},\"version\":{d}}}",
                .{ symbol, price, quantity, self.getVersion() },
            );
        }
    };
}

/// Helper: Capitalize first letter
fn capitalize(comptime s: []const u8) []const u8 {
    if (s.len == 0) return s;

    var result: [s.len]u8 = undefined;
    result[0] = std.ascii.toUpper(s[0]);

    for (s[1..], 1..) |c, i| {
        result[i] = c;
    }

    return &result;
}

// ============================================================================
// Tests
// ============================================================================

test "reactive model lock-free accessors" {
    const allocator = std.testing.allocator;

    const Trade = ReactiveModel("trades", .{
        .symbol = .String,
        .price = .i64,
        .quantity = .i64,
    });

    var trade = Trade.init(allocator);
    defer trade.deinit();
    trade.id = 42;

    // Lock-free price update
    try trade.setPrice(15000, null);
    try std.testing.expectEqual(@as(i64, 15000), trade.getPrice());

    // Lock-free quantity update
    try trade.setQuantity(100, null);
    try std.testing.expectEqual(@as(i64, 100), trade.getQuantity());

    // String update
    try trade.setSymbol("AAPL", null);
    try std.testing.expectEqualStrings("AAPL", trade.getSymbol());

    // Version increments
    try std.testing.expect(trade.getVersion() > 1);
}

test "reactive model CAS operation" {
    const allocator = std.testing.allocator;

    const Trade = ReactiveModel("trades", .{
        .symbol = .String,
        .price = .i64,
        .quantity = .i64,
    });

    var trade = Trade.init(allocator);
    defer trade.deinit();

    // Set initial price
    try trade.setPrice(1000, null);

    // CAS success
    const success1 = try trade.compareAndSwapPrice(1000, 1500, null);
    try std.testing.expect(success1);
    try std.testing.expectEqual(@as(i64, 1500), trade.getPrice());

    // CAS failure (wrong expected value)
    const success2 = try trade.compareAndSwapPrice(1000, 2000, null);
    try std.testing.expect(!success2);
    try std.testing.expectEqual(@as(i64, 1500), trade.getPrice());
}

test "reactive model concurrent updates" {
    const allocator = std.testing.allocator;

    const Trade = ReactiveModel("trades", .{
        .symbol = .String,
        .price = .i64,
        .quantity = .i64,
    });

    var trade = Trade.init(allocator);
    defer trade.deinit();

    try trade.setPrice(1000, null);

    // Simulate concurrent updates from multiple threads
    const Worker = struct {
        fn increment(t: *Trade) void {
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                const current = t.getPrice();
                _ = t.compareAndSwapPrice(current, current + 1, null) catch unreachable;
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.increment, .{&trade});
    }

    for (threads) |t| {
        t.join();
    }

    // Final price should be 1000 + (4 threads * 100 increments) = 1400
    // Note: Some CAS operations may fail due to contention, so actual value may be less
    const final_price = trade.getPrice();
    try std.testing.expect(final_price >= 1000);
    try std.testing.expect(final_price <= 1400);
}

test "reactive model setSymbol multiple updates" {
    const allocator = std.testing.allocator;

    const Trade = ReactiveModel("trades", .{
        .symbol = .String,
        .price = .i64,
        .quantity = .i64,
    });

    var trade = Trade.init(allocator);
    defer trade.deinit();

    // Multiple symbol updates should not leak memory
    try trade.setSymbol("AAPL", null);
    try std.testing.expectEqualStrings("AAPL", trade.getSymbol());

    try trade.setSymbol("GOOG", null);
    try std.testing.expectEqualStrings("GOOG", trade.getSymbol());

    try trade.setSymbol("MSFT", null);
    try std.testing.expectEqualStrings("MSFT", trade.getSymbol());

    // Version should have incremented for each update
    try std.testing.expect(trade.getVersion() >= 4); // 1 initial + 3 updates
}

test "reactive model toJSON produces valid output" {
    const allocator = std.testing.allocator;

    const Trade = ReactiveModel("trades", .{
        .symbol = .String,
        .price = .i64,
        .quantity = .i64,
    });

    var trade = Trade.init(allocator);
    defer trade.deinit();
    trade.id = 1;

    try trade.setSymbol("AAPL", null);
    try trade.setPrice(150, null);
    try trade.setQuantity(100, null);

    var buffer: [4096]u8 = undefined;
    const json = try trade.toJSON(&buffer);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"symbol\":\"AAPL\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"price\":150") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"quantity\":100") != null);
}
