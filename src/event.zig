const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("proto.zig");

/// Maximum number of typed fields per event for filtering
pub const MAX_EVENT_FIELDS = 8;

/// Stack-allocated fixed-size string for field values (no heap allocation).
/// 32 bytes — fits symbols ("AAPL"), statuses ("active"), short identifiers.
/// Keeps Event struct under 4 cache lines.
pub const FixedString = struct {
    buf: [32]u8 = undefined,
    len: u8 = 0,

    pub fn init(s: []const u8) FixedString {
        var fs = FixedString{};
        const copy_len: u8 = @intCast(@min(s.len, 32));
        @memcpy(fs.buf[0..copy_len], s[0..copy_len]);
        fs.len = copy_len;
        return fs;
    }

    pub fn slice(self: *const FixedString) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Typed field value for allocation-free filtering
pub const FieldValue = union(enum) {
    none,
    int: i64,
    uint: u64,
    float: f64,
    string: FixedString,
    boolean: bool,
};

/// Named typed field slot on an Event
pub const Field = struct {
    name: [32]u8 = undefined,
    name_len: u8 = 0,
    value: FieldValue = .none,

    pub fn init(field_name: []const u8, val: FieldValue) Field {
        var f = Field{};
        const copy_len: u8 = @intCast(@min(field_name.len, 32));
        @memcpy(f.name[0..copy_len], field_name[0..copy_len]);
        f.name_len = copy_len;
        f.value = val;
        return f;
    }

    pub fn nameSlice(self: *const Field) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Event payload for message bus
///
/// Memory ownership:
/// - Events created with initOwned() own their string data and must call deinit()
/// - Events created with struct literal syntax don't own data (caller manages lifetime)
/// - Check 'owned' field to determine if deinit() should be called
///
/// TODO(perf): This struct is ~400+ bytes (8 Fields × ~42 bytes each + metadata) and is
/// copied by value through the ring buffer on every push/pop. Consider indirecting via
/// pointer (pool-allocated Event*) if profiling shows memcpy as a bottleneck.
pub const Event = struct {
    id: u128, // UUID (generated with std.Random)
    timestamp: i64, // Unix timestamp microseconds
    event_type: EventType,
    topic: []const u8, // "Trade.created", "Trade.updated", etc.
    model_type: []const u8, // "Trade", "Portfolio", etc.
    model_id: u64,
    data: []const u8, // Serialized model state (protobuf)
    owned: bool = false, // If true, this Event owns its string data

    /// Subscription ID that caused this event (0 = no source / external).
    /// Used to prevent feedback loops: the event worker skips delivery
    /// back to this subscription, so a handler that mutates a model
    /// won't re-trigger itself from the model's auto-published event.
    source_subscription_id: u64 = 0,

    // Typed fields for allocation-free filtering (defaults preserve backward compat)
    fields: [MAX_EVENT_FIELDS]Field = [_]Field{.{}} ** MAX_EVENT_FIELDS,
    field_count: u8 = 0,

    /// Get a typed field value by name, or null if not found
    pub fn getField(self: *const Event, name: []const u8) ?FieldValue {
        for (self.fields[0..self.field_count]) |*f| {
            if (std.mem.eql(u8, f.nameSlice(), name)) {
                return f.value;
            }
        }
        return null;
    }

    /// Set a typed field on the event. If field_count is at MAX_EVENT_FIELDS, the call is a no-op.
    pub fn setField(self: *Event, name: []const u8, value: FieldValue) void {
        // Check if field already exists (update in place)
        for (self.fields[0..self.field_count]) |*f| {
            if (std.mem.eql(u8, f.nameSlice(), name)) {
                f.value = value;
                return;
            }
        }
        // Add new field
        if (self.field_count < MAX_EVENT_FIELDS) {
            self.fields[self.field_count] = Field.init(name, value);
            self.field_count += 1;
        }
    }

    pub const EventType = enum(u8) {
        model_created = 0,
        model_updated = 1,
        model_deleted = 2,
        custom = 255,
    };

    /// Create an event that owns its data (allocates copies)
    pub fn initOwned(
        allocator: Allocator,
        event_type: EventType,
        topic: []const u8,
        model_type: []const u8,
        model_id: u64,
        data: []const u8,
    ) !Event {
        const topic_copy = try allocator.dupe(u8, topic);
        errdefer allocator.free(topic_copy);
        const model_type_copy = try allocator.dupe(u8, model_type);
        errdefer allocator.free(model_type_copy);
        const data_copy = try allocator.dupe(u8, data);

        return Event{
            .id = generateEventId(),
            .timestamp = std.time.microTimestamp(),
            .event_type = event_type,
            .topic = topic_copy,
            .model_type = model_type_copy,
            .model_id = model_id,
            .data = data_copy,
            .owned = true,
        };
    }

    /// Serialize event to protobuf
    /// Protobuf schema:
    ///   message Event {
    ///     bytes id = 1;            // 16 bytes UUID
    ///     int64 timestamp = 2;
    ///     uint32 event_type = 3;
    ///     string topic = 4;
    ///     string model_type = 5;
    ///     uint64 model_id = 6;
    ///     bytes data = 7;          // Serialized model state
    ///   }
    pub fn serialize(self: *const Event, buffer: []u8) ![]const u8 {
        var pos: usize = 0;

        // Field 1: id (bytes - 16 byte UUID)
        var id_bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &id_bytes, self.id, .big);
        pos += try proto.encodeField(1, &id_bytes, buffer[pos..]);

        // Field 2: timestamp (int64)
        pos += try proto.encodeVarintField(2, self.timestamp, buffer[pos..]);

        // Field 3: event_type (uint32)
        const event_type_value = @intFromEnum(self.event_type);
        pos += try proto.encodeVarintField(3, event_type_value, buffer[pos..]);

        // Field 4: topic (string)
        pos += try proto.encodeField(4, self.topic, buffer[pos..]);

        // Field 5: model_type (string)
        pos += try proto.encodeField(5, self.model_type, buffer[pos..]);

        // Field 6: model_id (uint64)
        pos += try proto.encodeVarintField(6, @as(i64, @bitCast(self.model_id)), buffer[pos..]);

        // Field 7: data (bytes)
        pos += try proto.encodeField(7, self.data, buffer[pos..]);

        return buffer[0..pos];
    }

    /// Deserialize event from protobuf
    pub fn deserialize(pb_data: []const u8, allocator: Allocator) !Event {
        var event = Event{
            .id = 0,
            .timestamp = 0,
            .event_type = .custom,
            .topic = "",
            .model_type = "",
            .model_id = 0,
            .data = "",
            .owned = false, // Only set to true after all allocations succeed
        };

        // Track allocations for cleanup on error
        var topic_allocated: ?[]const u8 = null;
        errdefer if (topic_allocated) |t| allocator.free(t);
        var model_type_allocated: ?[]const u8 = null;
        errdefer if (model_type_allocated) |m| allocator.free(m);
        var data_allocated: ?[]const u8 = null;
        errdefer if (data_allocated) |d| allocator.free(d);

        var pos: usize = 0;

        while (pos < pb_data.len) {
            // Read tag
            const tag_result = try proto.decodeVarint(pb_data[pos..]);
            pos += tag_result.bytes_read;

            const field_number = @as(u32, @intCast(tag_result.value >> 3));
            const wire_type = @as(u3, @intCast(tag_result.value & 0x7));

            switch (field_number) {
                1 => { // id (bytes)
                    if (wire_type != @intFromEnum(proto.WireType.length_delimited)) return error.InvalidWireType;
                    const len_result = try proto.decodeVarint(pb_data[pos..]);
                    pos += len_result.bytes_read;
                    if (len_result.value > pb_data.len -| pos) return error.UnexpectedEof;
                    if (len_result.value < 16) return error.InvalidFieldLength;
                    const length: usize = @intCast(len_result.value);
                    const id_bytes = pb_data[pos..][0..length];
                    event.id = std.mem.readInt(u128, id_bytes[0..16], .big);
                    pos += length;
                },
                2 => { // timestamp (int64)
                    if (wire_type != @intFromEnum(proto.WireType.varint)) return error.InvalidWireType;
                    const val_result = try proto.decodeVarint(pb_data[pos..]);
                    pos += val_result.bytes_read;
                    // Decode zigzag
                    const unsigned = val_result.value;
                    event.timestamp = if ((unsigned & 1) == 0)
                        @intCast(unsigned >> 1)
                    else
                        -@as(i64, @intCast((unsigned >> 1) + 1));
                },
                3 => { // event_type (uint32)
                    if (wire_type != @intFromEnum(proto.WireType.varint)) return error.InvalidWireType;
                    const val_result = try proto.decodeVarint(pb_data[pos..]);
                    pos += val_result.bytes_read;
                    event.event_type = @enumFromInt(@as(u8, @intCast(val_result.value)));
                },
                4 => { // topic (string)
                    if (wire_type != @intFromEnum(proto.WireType.length_delimited)) return error.InvalidWireType;
                    const len_result = try proto.decodeVarint(pb_data[pos..]);
                    pos += len_result.bytes_read;
                    if (len_result.value > pb_data.len -| pos) return error.UnexpectedEof;
                    const length: usize = @intCast(len_result.value);
                    const topic_data = pb_data[pos..][0..length];
                    // Free previous value if field appears twice
                    if (topic_allocated) |t| allocator.free(t);
                    const duped = try allocator.dupe(u8, topic_data);
                    topic_allocated = duped;
                    event.topic = duped;
                    pos += length;
                },
                5 => { // model_type (string)
                    if (wire_type != @intFromEnum(proto.WireType.length_delimited)) return error.InvalidWireType;
                    const len_result = try proto.decodeVarint(pb_data[pos..]);
                    pos += len_result.bytes_read;
                    if (len_result.value > pb_data.len -| pos) return error.UnexpectedEof;
                    const length: usize = @intCast(len_result.value);
                    const model_type_data = pb_data[pos..][0..length];
                    if (model_type_allocated) |m| allocator.free(m);
                    const duped = try allocator.dupe(u8, model_type_data);
                    model_type_allocated = duped;
                    event.model_type = duped;
                    pos += length;
                },
                6 => { // model_id (uint64)
                    if (wire_type != @intFromEnum(proto.WireType.varint)) return error.InvalidWireType;
                    const val_result = try proto.decodeVarint(pb_data[pos..]);
                    pos += val_result.bytes_read;
                    // Decode zigzag to get signed value, then bitcast to unsigned
                    const unsigned = val_result.value;
                    const signed: i64 = if ((unsigned & 1) == 0)
                        @intCast(unsigned >> 1)
                    else
                        -@as(i64, @intCast((unsigned >> 1) + 1));
                    event.model_id = @bitCast(signed);
                },
                7 => { // data (bytes)
                    if (wire_type != @intFromEnum(proto.WireType.length_delimited)) return error.InvalidWireType;
                    const len_result = try proto.decodeVarint(pb_data[pos..]);
                    pos += len_result.bytes_read;
                    if (len_result.value > pb_data.len -| pos) return error.UnexpectedEof;
                    const length: usize = @intCast(len_result.value);
                    const data_bytes = pb_data[pos..][0..length];
                    if (data_allocated) |d| allocator.free(d);
                    const duped = try allocator.dupe(u8, data_bytes);
                    data_allocated = duped;
                    event.data = duped;
                    pos += length;
                },
                else => {
                    // Skip unknown field
                    if (wire_type == @intFromEnum(proto.WireType.length_delimited)) {
                        const len_result = try proto.decodeVarint(pb_data[pos..]);
                        pos += len_result.bytes_read;
                        if (len_result.value > pb_data.len -| pos) return error.UnexpectedEof;
                        pos += @as(usize, @intCast(len_result.value));
                    } else if (wire_type == @intFromEnum(proto.WireType.varint)) {
                        const val_result = try proto.decodeVarint(pb_data[pos..]);
                        pos += val_result.bytes_read;
                    } else {
                        return error.UnsupportedWireType;
                    }
                },
            }
        }

        // All allocations succeeded - mark as owned
        event.owned = true;
        return event;
    }

    pub fn deinit(self: Event, allocator: Allocator) void {
        if (!self.owned) return;

        // Zig allocators handle zero-length slices correctly — no guard needed.
        // Previous guards would leak zero-length owned allocations from dupe("").
        allocator.free(self.topic);
        allocator.free(self.model_type);
        allocator.free(self.data);
    }
};

/// Generate unique event ID using thread-local PRNG.
/// Previous implementation called std.crypto.random.bytes() which issues a
/// getrandom(2) syscall per event — ~200ns overhead on the hot path.
/// Thread-local PRNG seeds once from OS entropy, then generates IDs lock-free.
pub fn generateEventId() u128 {
    const State = struct {
        threadlocal var prng: ?std.Random.Xoshiro256 = null;
    };
    if (State.prng == null) {
        var seed_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&seed_bytes);
        State.prng = std.Random.Xoshiro256.init(@bitCast(seed_bytes));
    }
    var rng = State.prng.?;
    const lo: u128 = rng.next();
    const hi: u128 = rng.next();
    State.prng = rng;
    return (hi << 64) | lo;
}

test "event serialization and deserialization" {
    const allocator = std.testing.allocator;

    const event = Event{
        .id = 0x12345678_9abcdef0_12345678_9abcdef0,
        .timestamp = 1709568000000000,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 42,
        .data = "test_data",
    };

    // Serialize
    var buffer: [4096]u8 = undefined;
    const serialized = try event.serialize(&buffer);

    // Deserialize
    const deserialized = try Event.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);

    // Verify
    try std.testing.expectEqual(event.id, deserialized.id);
    try std.testing.expectEqual(event.timestamp, deserialized.timestamp);
    try std.testing.expectEqual(event.event_type, deserialized.event_type);
    try std.testing.expectEqualStrings(event.topic, deserialized.topic);
    try std.testing.expectEqualStrings(event.model_type, deserialized.model_type);
    try std.testing.expectEqual(event.model_id, deserialized.model_id);
    try std.testing.expectEqualStrings(event.data, deserialized.data);
}

test "event id generation" {
    const id1 = generateEventId();
    const id2 = generateEventId();

    // IDs should be different (very high probability)
    try std.testing.expect(id1 != id2);
}

test "event initOwned allocates and deinit frees correctly" {
    const allocator = std.testing.allocator;

    const event = try Event.initOwned(
        allocator,
        .model_created,
        "Trade.created",
        "Trade",
        42,
        "{\"price\":100}",
    );
    defer event.deinit(allocator);

    try std.testing.expect(event.owned);
    try std.testing.expectEqualStrings("Trade.created", event.topic);
    try std.testing.expectEqualStrings("Trade", event.model_type);
    try std.testing.expectEqualStrings("{\"price\":100}", event.data);
}

test "event deinit is safe for non-owned events" {
    const allocator = std.testing.allocator;

    // Non-owned event with string literals should not crash on deinit
    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{}",
        .owned = false,
    };

    // This should be a no-op, not a crash
    event.deinit(allocator);
}

test "event deserialize rejects truncated id field" {
    const allocator = std.testing.allocator;

    // Craft a protobuf with field 1 (id) with length < 16
    var bad_data: [10]u8 = undefined;
    var pos: usize = 0;

    // Tag: field 1, wire type 2 (length-delimited)
    bad_data[pos] = (1 << 3) | 2;
    pos += 1;

    // Length: 4 (too short for u128, needs 16)
    bad_data[pos] = 4;
    pos += 1;

    // 4 bytes of id data (insufficient)
    bad_data[pos] = 0x01;
    pos += 1;
    bad_data[pos] = 0x02;
    pos += 1;
    bad_data[pos] = 0x03;
    pos += 1;
    bad_data[pos] = 0x04;
    pos += 1;

    const result = Event.deserialize(bad_data[0..pos], allocator);
    try std.testing.expectError(error.InvalidFieldLength, result);
}

test "event deserialize handles empty input" {
    const allocator = std.testing.allocator;

    // Empty protobuf should produce default event
    const event = try Event.deserialize("", allocator);
    defer event.deinit(allocator);

    try std.testing.expectEqual(@as(u128, 0), event.id);
    try std.testing.expectEqual(@as(i64, 0), event.timestamp);
}
