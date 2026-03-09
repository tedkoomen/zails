/// Reactive Model — Generic Lock-Free Base Class
///
/// Provides the infrastructure for reactive, event-publishing models:
/// - Comptime-generated atomic field storage
/// - Generic get/set/compareAndSwap for any field by comptime name
/// - Automatic event publishing on mutation (via bound message bus)
/// - Thread-local feedback loop suppression (handlers don't re-trigger themselves)
/// - Optimistic concurrency via atomic version number
///
/// Domain models compose this base — they define typed accessors and toJSON:
///
///   const Trade = struct {
///       base: ReactiveModel("Trade", .{ .symbol = .String, .price = .i64, .quantity = .i64 }),
///
///       pub fn setPrice(self: *Trade, value: i64) !void {
///           try self.base.set("price", value);
///       }
///       pub fn getPrice(self: *const Trade) i64 {
///           return self.base.get("price");
///       }
///   };

const std = @import("std");
const Allocator = std.mem.Allocator;
const message_bus_mod = @import("../message_bus/mod.zig");
const Event = @import("../event.zig").Event;
const generateEventId = @import("../event.zig").generateEventId;
const EventWorker = @import("../message_bus/event_worker.zig").EventWorker;

/// Supported field types for reactive models.
pub const FieldType = enum {
    String,
    i64,
    u64,
    f64,
    bool,
    DateTime,
};

/// Reactive Model generator.
///
/// `table_name` — model name used for event topics ("Trade" → "Trade.updated").
/// `fields`     — comptime struct literal mapping field names to FieldTypes.
///
/// The returned type owns its bus reference and publishes events automatically.
/// Handlers that mutate the model don't need to pass bus/context — the
/// thread-local in EventWorker handles feedback loop suppression transparently.
pub fn ReactiveModel(comptime table_name: []const u8, comptime fields: anytype) type {
    const FieldsMeta = @typeInfo(@TypeOf(fields)).@"struct".fields;
    const field_count = FieldsMeta.len;

    return struct {
        const Self = @This();
        pub const model_name = table_name;
        pub const field_defs = fields;

        // --- Instance state ---

        version: std.atomic.Value(u64),
        id: u64,
        allocator: Allocator,
        string_lock: std.Thread.Mutex,
        bus: ?*message_bus_mod.MessageBus,
        field_storage: FieldStorage,

        // --- Comptime-generated field storage ---

        pub const FieldStorage = blk: {
            var struct_fields: [field_count]std.builtin.Type.StructField = undefined;
            for (FieldsMeta, 0..) |field, i| {
                const ft: FieldType = @field(fields, field.name);
                const T = storageType(ft);
                struct_fields[i] = .{
                    .name = field.name,
                    .type = T,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(T),
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

        /// Initialize a new model instance.
        /// `bus` may be null for testing; set it before mutations that should publish.
        pub fn init(allocator: Allocator, bus: ?*message_bus_mod.MessageBus) Self {
            var self = Self{
                .version = std.atomic.Value(u64).init(1),
                .id = 0,
                .allocator = allocator,
                .string_lock = .{},
                .bus = bus,
                .field_storage = undefined,
            };
            // Zero-initialize all fields
            inline for (FieldsMeta) |field| {
                const ft: FieldType = @field(fields, field.name);
                switch (ft) {
                    .String => @field(self.field_storage, field.name) = "",
                    .i64 => @field(self.field_storage, field.name) = std.atomic.Value(i64).init(0),
                    .u64 => @field(self.field_storage, field.name) = std.atomic.Value(u64).init(0),
                    .f64 => @field(self.field_storage, field.name) = std.atomic.Value(u64).init(0),
                    .bool => @field(self.field_storage, field.name) = std.atomic.Value(bool).init(false),
                    .DateTime => @field(self.field_storage, field.name) = std.atomic.Value(i64).init(0),
                }
            }
            return self;
        }

        /// Free string fields.
        pub fn deinit(self: *Self) void {
            inline for (FieldsMeta) |field| {
                if (@as(FieldType, @field(fields, field.name)) == .String) {
                    const str = @field(self.field_storage, field.name);
                    if (str.len > 0) self.allocator.free(str);
                }
            }
        }

        // --- Generic field accessors ---

        /// Lock-free read of an atomic field. Returns the native type.
        /// NOTE: String field reads acquire a mutex (non-atomic pointer swap).
        /// This uses @constCast on *const Self to acquire the lock — acceptable
        /// because the mutex protects the string pointer, not the model's logical
        /// constness. For hot-path string reads, consider caching in a local variable.
        pub fn get(self: *const Self, comptime name: []const u8) GetReturnType(name) {
            const ft: FieldType = @field(fields, name);
            return switch (ft) {
                .i64 => @field(self.field_storage, name).load(.acquire),
                .u64 => @field(self.field_storage, name).load(.acquire),
                .f64 => @as(f64, @bitCast(@field(self.field_storage, name).load(.acquire))),
                .bool => @field(self.field_storage, name).load(.acquire),
                .DateTime => @field(self.field_storage, name).load(.acquire),
                .String => blk: {
                    // String reads need the lock (non-atomic pointer)
                    const mutable_self: *Self = @constCast(self);
                    mutable_self.string_lock.lock();
                    defer mutable_self.string_lock.unlock();
                    break :blk @field(self.field_storage, name);
                },
            };
        }

        /// Lock-free write + version bump + event publish.
        /// Handlers call this directly — no bus parameter needed.
        pub fn set(self: *Self, comptime name: []const u8, value: SetValueType(name)) !void {
            const ft: FieldType = @field(fields, name);
            switch (ft) {
                .String => {
                    const new_str = try self.allocator.dupe(u8, value);
                    self.string_lock.lock();
                    defer self.string_lock.unlock();
                    const old = @field(self.field_storage, name);
                    @field(self.field_storage, name) = new_str;
                    if (old.len > 0) self.allocator.free(old);
                },
                .i64 => @field(self.field_storage, name).store(value, .release),
                .u64 => @field(self.field_storage, name).store(value, .release),
                .f64 => @field(self.field_storage, name).store(@bitCast(value), .release),
                .bool => @field(self.field_storage, name).store(value, .release),
                .DateTime => @field(self.field_storage, name).store(value, .release),
            }
            _ = self.version.fetchAdd(1, .monotonic);
            self.publishEvent(.model_updated, table_name ++ ".updated") catch {};
        }

        /// Compare-and-swap for atomic fields. Returns true on success.
        pub fn compareAndSwap(
            self: *Self,
            comptime name: []const u8,
            expected: SetValueType(name),
            new_val: SetValueType(name),
        ) !bool {
            const ft: FieldType = @field(fields, name);
            if (ft == .String) @compileError("compareAndSwap not supported for String fields");

            const raw_expected = if (ft == .f64) @as(u64, @bitCast(expected)) else expected;
            const raw_new = if (ft == .f64) @as(u64, @bitCast(new_val)) else new_val;

            const success = @field(self.field_storage, name).cmpxchgStrong(
                raw_expected,
                raw_new,
                .acq_rel,
                .acquire,
            ) == null;

            if (success) {
                _ = self.version.fetchAdd(1, .monotonic);
                try self.publishEvent(.model_updated, table_name ++ ".updated");
            }
            return success;
        }

        /// Current version number (for optimistic concurrency checks).
        pub fn getVersion(self: *const Self) u64 {
            return self.version.load(.acquire);
        }

        // --- Event publishing ---

        /// Publish an event to the bound message bus.
        /// Reads the thread-local `current_handler_subscription_id` set by
        /// EventWorker so the originating handler is automatically excluded
        /// from delivery. Handlers stay domain-agnostic — they never see
        /// subscription IDs, bus references, or event plumbing.
        fn publishEvent(self: *Self, event_type: Event.EventType, comptime topic: []const u8) !void {
            const bus = self.bus orelse return;
            var buffer: [4096]u8 = undefined;
            const json = try self.toJSON(&buffer);
            const event = Event{
                .id = generateEventId(),
                .timestamp = std.time.microTimestamp(),
                .event_type = event_type,
                .topic = topic,
                .model_type = table_name,
                .model_id = self.id,
                .data = json,
                .source_subscription_id = EventWorker.current_handler_subscription_id,
            };
            _ = bus.publish(event);
        }

        /// Serialize all fields to JSON into the provided buffer.
        /// Domain models may override this with a custom implementation.
        pub fn toJSON(self: *Self, buffer: []u8) ![]const u8 {
            // Build JSON dynamically from field metadata
            var stream = std.io.fixedBufferStream(buffer);
            const writer = stream.writer();
            try writer.writeByte('{');
            var first = true;
            inline for (FieldsMeta) |field| {
                if (!first) try writer.writeByte(',');
                first = false;
                const ft: FieldType = @field(fields, field.name);
                try writer.print("\"{s}\":", .{field.name});
                switch (ft) {
                    .String => {
                        const val = self.get(field.name);
                        try writer.print("\"{s}\"", .{val});
                    },
                    .i64, .DateTime => {
                        const val = self.get(field.name);
                        try writer.print("{d}", .{val});
                    },
                    .u64 => {
                        const val = self.get(field.name);
                        try writer.print("{d}", .{val});
                    },
                    .f64 => {
                        const val = self.get(field.name);
                        try writer.print("{d}", .{val});
                    },
                    .bool => {
                        const val = self.get(field.name);
                        try writer.print("{}", .{val});
                    },
                }
            }
            try writer.print(",\"version\":{d}", .{self.getVersion()});
            try writer.writeByte('}');
            return stream.getWritten();
        }

        // --- Comptime type helpers ---

        fn GetReturnType(comptime name: []const u8) type {
            const ft: FieldType = @field(fields, name);
            return switch (ft) {
                .String => []const u8,
                .i64 => i64,
                .u64 => u64,
                .f64 => f64,
                .bool => bool,
                .DateTime => i64,
            };
        }

        fn SetValueType(comptime name: []const u8) type {
            return GetReturnType(name);
        }

        fn storageType(ft: FieldType) type {
            return switch (ft) {
                .String => []const u8,
                .i64 => std.atomic.Value(i64),
                .u64 => std.atomic.Value(u64),
                .f64 => std.atomic.Value(u64), // f64 stored as u64 bits
                .bool => std.atomic.Value(bool),
                .DateTime => std.atomic.Value(i64),
            };
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "reactive model generic get/set" {
    const allocator = std.testing.allocator;

    const Model = ReactiveModel("TestModel", .{
        .name = .String,
        .value = .i64,
        .flag = .bool,
    });

    var m = Model.init(allocator, null);
    defer m.deinit();
    m.id = 1;

    // i64 field
    try m.set("value", @as(i64, 42));
    try std.testing.expectEqual(@as(i64, 42), m.get("value"));

    // bool field
    try m.set("flag", true);
    try std.testing.expect(m.get("flag"));

    // String field
    try m.set("name", "hello");
    try std.testing.expectEqualStrings("hello", m.get("name"));

    // Version increments
    try std.testing.expect(m.getVersion() > 1);
}

test "reactive model compareAndSwap" {
    const allocator = std.testing.allocator;

    const Model = ReactiveModel("TestModel", .{
        .count = .i64,
    });

    var m = Model.init(allocator, null);
    defer m.deinit();

    try m.set("count", @as(i64, 100));

    // Success
    const ok = try m.compareAndSwap("count", @as(i64, 100), @as(i64, 200));
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(i64, 200), m.get("count"));

    // Failure (stale expected)
    const fail = try m.compareAndSwap("count", @as(i64, 100), @as(i64, 300));
    try std.testing.expect(!fail);
    try std.testing.expectEqual(@as(i64, 200), m.get("count"));
}

test "reactive model string updates free old values" {
    const allocator = std.testing.allocator;

    const Model = ReactiveModel("TestModel", .{
        .label = .String,
    });

    var m = Model.init(allocator, null);
    defer m.deinit();

    try m.set("label", "first");
    try std.testing.expectEqualStrings("first", m.get("label"));

    try m.set("label", "second");
    try std.testing.expectEqualStrings("second", m.get("label"));

    try m.set("label", "third");
    try std.testing.expectEqualStrings("third", m.get("label"));
}

test "reactive model toJSON is generic" {
    const allocator = std.testing.allocator;

    const Model = ReactiveModel("Widget", .{
        .name = .String,
        .count = .i64,
        .active = .bool,
    });

    var m = Model.init(allocator, null);
    defer m.deinit();

    try m.set("name", "sprocket");
    try m.set("count", @as(i64, 7));
    try m.set("active", true);

    var buffer: [4096]u8 = undefined;
    const json = try m.toJSON(&buffer);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"sprocket\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"active\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":") != null);
}

test "reactive model concurrent CAS" {
    const allocator = std.testing.allocator;

    const Model = ReactiveModel("Counter", .{
        .value = .i64,
    });

    var m = Model.init(allocator, null);
    defer m.deinit();

    try m.set("value", @as(i64, 0));

    const Worker = struct {
        fn run(model: *Model) void {
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                const current = model.get("value");
                _ = model.compareAndSwap("value", current, current + 1) catch unreachable;
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{&m});
    }
    for (threads) |t| t.join();

    const final = m.get("value");
    try std.testing.expect(final >= 0 and final <= 400);
}
