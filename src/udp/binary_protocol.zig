/// Comptime Binary Protocol Generator
///
/// Generates zero-cost parsers from field/offset/type definitions.
/// All field iteration uses `inline for` — zero runtime overhead.
///
/// Example:
///   const AddOrder = BinaryProtocol("ITCH_AddOrder", .{
///       .msg_type     = .{ .type = .u8,    .offset = 0 },
///       .stock_locate = .{ .type = .u16,   .offset = 1 },
///       .shares       = .{ .type = .u32,   .offset = 3 },
///       .stock        = .{ .type = .ascii, .offset = 7, .size = 8 },
///   });
///
///   const result = AddOrder.parse(datagram);

const std = @import("std");

/// Field types supported in binary protocol definitions
pub const BinaryFieldType = enum {
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,
    ascii,
    raw_bytes,
};

/// Definition of a single field in a binary protocol message
pub const BinaryFieldDef = struct {
    type: BinaryFieldType,
    offset: usize,
    size: usize = 0, // Required for .ascii / .raw_bytes
    endian: std.builtin.Endian = .big, // Network byte order default
};

/// Feed error codes - Tiger Style (errors as values)
pub const FeedError = enum(u8) {
    none = 0,
    message_too_short = 1,
    unknown_message_type = 2,
    buffer_too_small = 3,
};

/// Convert an anonymous struct field to a proper BinaryFieldDef at comptime.
/// This handles the case where users pass `.{ .type = .u8, .offset = 0 }`
/// (anonymous struct literal) which can't directly coerce to BinaryFieldDef.
fn toDef(comptime raw: anytype) BinaryFieldDef {
    return .{
        .type = raw.type,
        .offset = raw.offset,
        .size = if (@hasField(@TypeOf(raw), "size")) raw.size else 0,
        .endian = if (@hasField(@TypeOf(raw), "endian")) raw.endian else .big,
    };
}

/// Returns the byte size of a field type (for fixed-width types)
fn fieldByteSize(comptime def: BinaryFieldDef) usize {
    return switch (def.type) {
        .u8, .i8 => 1,
        .u16, .i16 => 2,
        .u32, .i32, .f32 => 4,
        .u64, .i64, .f64 => 8,
        .ascii, .raw_bytes => def.size,
    };
}

/// Maps a BinaryFieldType to the corresponding Zig type
fn BinaryFieldToZigType(comptime def: BinaryFieldDef) type {
    return switch (def.type) {
        .u8 => u8,
        .u16 => u16,
        .u32 => u32,
        .u64 => u64,
        .i8 => i8,
        .i16 => i16,
        .i32 => i32,
        .i64 => i64,
        .f32 => f32,
        .f64 => f64,
        .ascii, .raw_bytes => [def.size]u8,
    };
}

/// Comptime binary protocol generator
/// Produces a ParsedMessage struct and parse/toJSON functions from field definitions.
pub fn BinaryProtocol(comptime name: []const u8, comptime fields: anytype) type {
    const field_info = @typeInfo(@TypeOf(fields)).@"struct";
    const field_count = field_info.fields.len;

    // Pre-compute BinaryFieldDef for each field
    const defs = comptime blk: {
        var result: [field_count]BinaryFieldDef = undefined;
        for (field_info.fields, 0..) |f, i| {
            result[i] = toDef(@field(fields, f.name));
        }
        break :blk result;
    };

    // Compute MIN_MESSAGE_SIZE from max(offset + fieldSize) across all fields
    const computed_min_size = comptime blk: {
        var max_end: usize = 0;
        for (defs) |def| {
            const end = def.offset + fieldByteSize(def);
            if (end > max_end) max_end = end;
        }
        break :blk max_end;
    };

    // Generate ParsedMessage struct via @Type
    const ParsedMessage = comptime blk: {
        var struct_fields: [field_count]std.builtin.Type.StructField = undefined;
        for (field_info.fields, 0..) |f, i| {
            const FieldType = BinaryFieldToZigType(defs[i]);
            struct_fields[i] = .{
                .name = f.name,
                .type = FieldType,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = if (@alignOf(FieldType) > 0) @alignOf(FieldType) else 1,
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

    return struct {
        pub const protocol_name = name;
        pub const MIN_MESSAGE_SIZE = computed_min_size;
        pub const Message = ParsedMessage;

        /// Parse result - Tiger Style (errors as values, not exceptions)
        pub const ParseResult = struct {
            msg: ParsedMessage,
            error_code: FeedError,

            pub fn ok(msg: ParsedMessage) ParseResult {
                return .{ .msg = msg, .error_code = .none };
            }

            pub fn err(code: FeedError) ParseResult {
                return .{ .msg = undefined, .error_code = code };
            }

            pub fn isOk(self: ParseResult) bool {
                return self.error_code == .none;
            }

            pub fn isErr(self: ParseResult) bool {
                return self.error_code != .none;
            }
        };

        /// Zero-copy parse of a datagram into ParsedMessage
        /// Uses comptime-known offsets — zero runtime overhead
        pub fn parse(datagram: []const u8) ParseResult {
            if (datagram.len < MIN_MESSAGE_SIZE) {
                return ParseResult.err(.message_too_short);
            }

            var msg: ParsedMessage = undefined;

            inline for (field_info.fields, 0..) |f, idx| {
                const def = comptime defs[idx];
                const byte_size = comptime fieldByteSize(def);
                const slice = datagram[def.offset..][0..byte_size];

                @field(msg, f.name) = switch (def.type) {
                    .u8 => slice[0],
                    .u16 => std.mem.readInt(u16, slice[0..2], def.endian),
                    .u32 => std.mem.readInt(u32, slice[0..4], def.endian),
                    .u64 => std.mem.readInt(u64, slice[0..8], def.endian),
                    .i8 => @bitCast(slice[0]),
                    .i16 => std.mem.readInt(i16, slice[0..2], def.endian),
                    .i32 => std.mem.readInt(i32, slice[0..4], def.endian),
                    .i64 => std.mem.readInt(i64, slice[0..8], def.endian),
                    .f32 => @bitCast(std.mem.readInt(u32, slice[0..4], def.endian)),
                    .f64 => @bitCast(std.mem.readInt(u64, slice[0..8], def.endian)),
                    .ascii, .raw_bytes => slice[0..def.size].*,
                };
            }

            return ParseResult.ok(msg);
        }

        /// Serialize parsed message to JSON in a stack buffer
        pub fn toJSON(msg: *const ParsedMessage, buf: []u8) ![]const u8 {
            var stream = std.io.fixedBufferStream(buf);
            const writer = stream.writer();

            try writer.writeByte('{');

            comptime var first = true;
            inline for (field_info.fields, 0..) |f, idx| {
                const def = comptime defs[idx];

                if (!first) {
                    try writer.writeByte(',');
                }
                first = false;

                try writer.writeByte('"');
                try writer.writeAll(f.name);
                try writer.writeAll("\":");

                const value = @field(msg, f.name);

                switch (def.type) {
                    .u8, .u16, .u32, .u64 => {
                        try std.fmt.format(writer, "{d}", .{value});
                    },
                    .i8, .i16, .i32, .i64 => {
                        try std.fmt.format(writer, "{d}", .{value});
                    },
                    .f32, .f64 => {
                        try std.fmt.format(writer, "{d}", .{value});
                    },
                    .ascii => {
                        // Trim trailing spaces/nulls for ASCII fields
                        const trimmed = std.mem.trimRight(u8, &value, &[_]u8{ 0, ' ' });
                        try writer.writeByte('"');
                        try writer.writeAll(trimmed);
                        try writer.writeByte('"');
                    },
                    .raw_bytes => {
                        // Output as hex string
                        try writer.writeByte('"');
                        for (value) |byte| {
                            try std.fmt.format(writer, "{x:0>2}", .{byte});
                        }
                        try writer.writeByte('"');
                    },
                }
            }

            try writer.writeByte('}');

            return stream.getWritten();
        }
    };
}

// ====================
// Tests
// ====================

test "BinaryProtocol parse correctness" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
        .count = .{ .type = .u16, .offset = 1 },
        .value = .{ .type = .u32, .offset = 3 },
    });

    // MIN_MESSAGE_SIZE = 3 + 4 = 7
    try std.testing.expectEqual(@as(usize, 7), TestMsg.MIN_MESSAGE_SIZE);

    // Build test datagram (big-endian)
    var data: [7]u8 = undefined;
    data[0] = 42; // msg_type
    std.mem.writeInt(u16, data[1..3], 1000, .big); // count
    std.mem.writeInt(u32, data[3..7], 123456, .big); // value

    const result = TestMsg.parse(&data);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqual(@as(u8, 42), result.msg.msg_type);
    try std.testing.expectEqual(@as(u16, 1000), result.msg.count);
    try std.testing.expectEqual(@as(u32, 123456), result.msg.value);
}

test "BinaryProtocol message too short" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
        .value = .{ .type = .u32, .offset = 1 },
    });

    const short_data = [_]u8{ 0x01, 0x02 };
    const result = TestMsg.parse(&short_data);
    try std.testing.expect(result.isErr());
    try std.testing.expectEqual(FeedError.message_too_short, result.error_code);
}

test "BinaryProtocol little-endian fields" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .value = .{ .type = .u32, .offset = 0, .endian = .little },
    });

    var data: [4]u8 = undefined;
    std.mem.writeInt(u32, &data, 0xDEADBEEF, .little);

    const result = TestMsg.parse(&data);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), result.msg.value);
}

test "BinaryProtocol ASCII fields" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
        .symbol = .{ .type = .ascii, .offset = 1, .size = 8 },
    });

    try std.testing.expectEqual(@as(usize, 9), TestMsg.MIN_MESSAGE_SIZE);

    var data: [9]u8 = undefined;
    data[0] = 1;
    @memcpy(data[1..9], "AAPL    "); // 4 chars + 4 spaces

    const result = TestMsg.parse(&data);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqualStrings("AAPL    ", &result.msg.symbol);
}

test "BinaryProtocol signed integer fields" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .val8 = .{ .type = .i8, .offset = 0 },
        .val16 = .{ .type = .i16, .offset = 1 },
        .val32 = .{ .type = .i32, .offset = 3 },
        .val64 = .{ .type = .i64, .offset = 7 },
    });

    var data: [15]u8 = undefined;
    data[0] = @bitCast(@as(i8, -42));
    std.mem.writeInt(i16, data[1..3], -1000, .big);
    std.mem.writeInt(i32, data[3..7], -123456, .big);
    std.mem.writeInt(i64, data[7..15], -9876543210, .big);

    const result = TestMsg.parse(&data);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqual(@as(i8, -42), result.msg.val8);
    try std.testing.expectEqual(@as(i16, -1000), result.msg.val16);
    try std.testing.expectEqual(@as(i32, -123456), result.msg.val32);
    try std.testing.expectEqual(@as(i64, -9876543210), result.msg.val64);
}

test "BinaryProtocol float fields" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .f32_val = .{ .type = .f32, .offset = 0 },
        .f64_val = .{ .type = .f64, .offset = 4 },
    });

    var data: [12]u8 = undefined;
    const f32_bits: u32 = @bitCast(@as(f32, 3.14));
    const f64_bits: u64 = @bitCast(@as(f64, 2.71828));
    std.mem.writeInt(u32, data[0..4], f32_bits, .big);
    std.mem.writeInt(u64, data[4..12], f64_bits, .big);

    const result = TestMsg.parse(&data);
    try std.testing.expect(result.isOk());
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), result.msg.f32_val, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.71828), result.msg.f64_val, 0.00001);
}

test "BinaryProtocol toJSON output" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
        .count = .{ .type = .u16, .offset = 1 },
        .symbol = .{ .type = .ascii, .offset = 3, .size = 4 },
    });

    var data: [7]u8 = undefined;
    data[0] = 65;
    std.mem.writeInt(u16, data[1..3], 500, .big);
    @memcpy(data[3..7], "MSFT");

    const parse_result = TestMsg.parse(&data);
    try std.testing.expect(parse_result.isOk());

    var json_buf: [256]u8 = undefined;
    const json = try TestMsg.toJSON(&parse_result.msg, &json_buf);

    try std.testing.expectEqualStrings(
        "{\"msg_type\":65,\"count\":500,\"symbol\":\"MSFT\"}",
        json,
    );
}

test "BinaryProtocol toJSON buffer too small" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
        .value = .{ .type = .u64, .offset = 1 },
    });

    var data: [9]u8 = undefined;
    data[0] = 1;
    std.mem.writeInt(u64, data[1..9], 99999999999, .big);

    const parse_result = TestMsg.parse(&data);
    try std.testing.expect(parse_result.isOk());

    // Buffer too small
    var tiny_buf: [5]u8 = undefined;
    const result = TestMsg.toJSON(&parse_result.msg, &tiny_buf);
    try std.testing.expectError(error.NoSpaceLeft, result);
}

test "BinaryProtocol raw_bytes fields" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .header = .{ .type = .raw_bytes, .offset = 0, .size = 4 },
    });

    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const result = TestMsg.parse(&data);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }, &result.msg.header);

    // JSON should output hex
    var json_buf: [64]u8 = undefined;
    const json = try TestMsg.toJSON(&result.msg, &json_buf);
    try std.testing.expectEqualStrings("{\"header\":\"deadbeef\"}", json);
}

test "BinaryProtocol ITCH-like round-trip" {
    const AddOrder = BinaryProtocol("ITCH_AddOrder", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
        .stock_locate = .{ .type = .u16, .offset = 1 },
        .tracking_num = .{ .type = .u16, .offset = 3 },
        .timestamp_ns = .{ .type = .u64, .offset = 5 },
        .order_ref = .{ .type = .u64, .offset = 13 },
        .side = .{ .type = .u8, .offset = 21 },
        .shares = .{ .type = .u32, .offset = 22 },
        .stock = .{ .type = .ascii, .offset = 26, .size = 8 },
        .price = .{ .type = .u32, .offset = 34 },
    });

    try std.testing.expectEqual(@as(usize, 38), AddOrder.MIN_MESSAGE_SIZE);

    // Build a test message
    var data: [38]u8 = undefined;
    data[0] = 'A'; // msg_type = Add Order
    std.mem.writeInt(u16, data[1..3], 42, .big); // stock_locate
    std.mem.writeInt(u16, data[3..5], 0, .big); // tracking_num
    std.mem.writeInt(u64, data[5..13], 1234567890123, .big); // timestamp_ns
    std.mem.writeInt(u64, data[13..21], 100001, .big); // order_ref
    data[21] = 'B'; // side = Buy
    std.mem.writeInt(u32, data[22..26], 500, .big); // shares
    @memcpy(data[26..34], "AAPL    "); // stock
    std.mem.writeInt(u32, data[34..38], 15000, .big); // price (150.00 * 100)

    const result = AddOrder.parse(&data);
    try std.testing.expect(result.isOk());

    try std.testing.expectEqual(@as(u8, 'A'), result.msg.msg_type);
    try std.testing.expectEqual(@as(u16, 42), result.msg.stock_locate);
    try std.testing.expectEqual(@as(u64, 1234567890123), result.msg.timestamp_ns);
    try std.testing.expectEqual(@as(u64, 100001), result.msg.order_ref);
    try std.testing.expectEqual(@as(u8, 'B'), result.msg.side);
    try std.testing.expectEqual(@as(u32, 500), result.msg.shares);
    try std.testing.expectEqualStrings("AAPL    ", &result.msg.stock);
    try std.testing.expectEqual(@as(u32, 15000), result.msg.price);

    // Also verify JSON
    var json_buf: [512]u8 = undefined;
    const json = try AddOrder.toJSON(&result.msg, &json_buf);

    // Should contain key fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"msg_type\":65") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shares\":500") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stock\":\"AAPL\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"price\":15000") != null);
}

test "BinaryProtocol empty datagram" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
    });

    const result = TestMsg.parse(&[_]u8{});
    try std.testing.expect(result.isErr());
    try std.testing.expectEqual(FeedError.message_too_short, result.error_code);
}

test "BinaryProtocol exact MIN_MESSAGE_SIZE datagram" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
        .value = .{ .type = .u16, .offset = 1 },
    });

    // Exactly MIN_MESSAGE_SIZE bytes (3)
    try std.testing.expectEqual(@as(usize, 3), TestMsg.MIN_MESSAGE_SIZE);
    var data: [3]u8 = undefined;
    data[0] = 0xFF;
    std.mem.writeInt(u16, data[1..3], 0x1234, .big);

    const result = TestMsg.parse(&data);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqual(@as(u8, 0xFF), result.msg.msg_type);
    try std.testing.expectEqual(@as(u16, 0x1234), result.msg.value);
}

test "BinaryProtocol datagram larger than MIN_MESSAGE_SIZE" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .msg_type = .{ .type = .u8, .offset = 0 },
    });

    // Datagram with extra trailing bytes should parse fine
    const data = [_]u8{ 42, 0xFF, 0xAB, 0xCD };
    const result = TestMsg.parse(&data);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqual(@as(u8, 42), result.msg.msg_type);
}

test "BinaryProtocol overlapping fields" {
    // Fields can overlap — both read from the same bytes
    const TestMsg = BinaryProtocol("TestMsg", .{
        .full_word = .{ .type = .u32, .offset = 0 },
        .high_byte = .{ .type = .u8, .offset = 0 },
        .low_byte = .{ .type = .u8, .offset = 3 },
    });

    var data: [4]u8 = undefined;
    std.mem.writeInt(u32, &data, 0xAABBCCDD, .big);

    const result = TestMsg.parse(&data);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), result.msg.full_word);
    try std.testing.expectEqual(@as(u8, 0xAA), result.msg.high_byte);
    try std.testing.expectEqual(@as(u8, 0xDD), result.msg.low_byte);
}

test "BinaryProtocol single field" {
    const TestMsg = BinaryProtocol("SingleByte", .{
        .value = .{ .type = .u8, .offset = 0 },
    });

    try std.testing.expectEqual(@as(usize, 1), TestMsg.MIN_MESSAGE_SIZE);

    const data = [_]u8{0x42};
    const result = TestMsg.parse(&data);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqual(@as(u8, 0x42), result.msg.value);
}

test "BinaryProtocol all-zero datagram" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .a = .{ .type = .u8, .offset = 0 },
        .b = .{ .type = .u32, .offset = 1 },
        .c = .{ .type = .u64, .offset = 5 },
    });

    const data = [_]u8{0} ** 13;
    const result = TestMsg.parse(&data);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqual(@as(u8, 0), result.msg.a);
    try std.testing.expectEqual(@as(u32, 0), result.msg.b);
    try std.testing.expectEqual(@as(u64, 0), result.msg.c);
}

test "BinaryProtocol all-0xFF datagram" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .a = .{ .type = .u8, .offset = 0 },
        .b = .{ .type = .u16, .offset = 1 },
        .c = .{ .type = .i16, .offset = 3 },
    });

    const data = [_]u8{0xFF} ** 5;
    const result = TestMsg.parse(&data);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqual(@as(u8, 0xFF), result.msg.a);
    try std.testing.expectEqual(@as(u16, 0xFFFF), result.msg.b);
    try std.testing.expectEqual(@as(i16, -1), result.msg.c);
}

test "BinaryProtocol toJSON with all zero values" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .a = .{ .type = .u8, .offset = 0 },
        .b = .{ .type = .u32, .offset = 1 },
    });

    const data = [_]u8{0} ** 5;
    const parse_result = TestMsg.parse(&data);
    try std.testing.expect(parse_result.isOk());

    var json_buf: [64]u8 = undefined;
    const json = try TestMsg.toJSON(&parse_result.msg, &json_buf);
    try std.testing.expectEqualStrings("{\"a\":0,\"b\":0}", json);
}

test "BinaryProtocol toJSON with negative signed values" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .val = .{ .type = .i32, .offset = 0 },
    });

    var data: [4]u8 = undefined;
    std.mem.writeInt(i32, &data, -12345, .big);

    const parse_result = TestMsg.parse(&data);
    try std.testing.expect(parse_result.isOk());

    var json_buf: [64]u8 = undefined;
    const json = try TestMsg.toJSON(&parse_result.msg, &json_buf);
    try std.testing.expectEqualStrings("{\"val\":-12345}", json);
}

test "BinaryProtocol ASCII field with all nulls" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .name = .{ .type = .ascii, .offset = 0, .size = 8 },
    });

    const data = [_]u8{0} ** 8;
    const parse_result = TestMsg.parse(&data);
    try std.testing.expect(parse_result.isOk());

    var json_buf: [64]u8 = undefined;
    const json = try TestMsg.toJSON(&parse_result.msg, &json_buf);
    // All nulls trimmed -> empty string
    try std.testing.expectEqualStrings("{\"name\":\"\"}", json);
}

test "BinaryProtocol ParseResult error has undefined msg" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .value = .{ .type = .u32, .offset = 0 },
    });

    const result = TestMsg.ParseResult.err(.message_too_short);
    try std.testing.expect(result.isErr());
    try std.testing.expect(!result.isOk());
    try std.testing.expectEqual(FeedError.message_too_short, result.error_code);
}

test "BinaryProtocol mixed endian fields" {
    const TestMsg = BinaryProtocol("TestMsg", .{
        .big_val = .{ .type = .u16, .offset = 0, .endian = .big },
        .little_val = .{ .type = .u16, .offset = 2, .endian = .little },
    });

    var data: [4]u8 = undefined;
    std.mem.writeInt(u16, data[0..2], 0x1234, .big);
    std.mem.writeInt(u16, data[2..4], 0x5678, .little);

    const result = TestMsg.parse(&data);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqual(@as(u16, 0x1234), result.msg.big_val);
    try std.testing.expectEqual(@as(u16, 0x5678), result.msg.little_val);
}
