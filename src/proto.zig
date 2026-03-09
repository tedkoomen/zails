const std = @import("std");
const Allocator = std.mem.Allocator;

/// Wire types for protobuf encoding
pub const WireType = enum(u3) {
    varint = 0,
    fixed64 = 1,
    length_delimited = 2,
    start_group = 3,
    end_group = 4,
    fixed32 = 5,
};

/// Generic base request that all requests should embed
pub const BaseRequest = struct {
    request_id: []const u8 = "",
    timestamp: i64 = 0,
    metadata: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator) BaseRequest {
        return .{
            .metadata = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *BaseRequest, allocator: Allocator) void {
        if (self.request_id.len > 0) allocator.free(self.request_id);

        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};

/// Echo request message
pub const EchoRequest = struct {
    base: BaseRequest,
    message: []const u8 = "",

    pub fn init(allocator: Allocator) EchoRequest {
        return .{
            .base = BaseRequest.init(allocator),
        };
    }

    pub fn deinit(self: *EchoRequest, allocator: Allocator) void {
        self.base.deinit(allocator);
        if (self.message.len > 0) allocator.free(self.message);
    }
};

/// Echo response message
pub const EchoResponse = struct {
    request_id: []const u8 = "",
    message: []const u8 = "",
    timestamp: i64 = 0,

    pub fn deinit(self: *EchoResponse, allocator: Allocator) void {
        if (self.request_id.len > 0) allocator.free(self.request_id);
        if (self.message.len > 0) allocator.free(self.message);
    }
};

/// Simple varint encoding
pub fn encodeVarint(value: u64, buffer: []u8) !usize {
    var v = value;
    var i: usize = 0;

    while (v >= 0x80) {
        if (i >= buffer.len) return error.BufferTooSmall;
        buffer[i] = @as(u8, @intCast(v & 0x7F)) | 0x80;
        v >>= 7;
        i += 1;
    }

    if (i >= buffer.len) return error.BufferTooSmall;
    buffer[i] = @as(u8, @intCast(v));
    return i + 1;
}

/// Simple varint decoding
pub fn decodeVarint(buffer: []const u8) !struct { value: u64, bytes_read: usize } {
    var result_val: u64 = 0;
    var i: usize = 0;

    // A u64 varint is at most 10 bytes (ceil(64/7))
    const max_bytes = 10;

    while (i < buffer.len) {
        if (i >= max_bytes) return error.VarintTooLong;

        const byte = buffer[i];
        const shift: u6 = @intCast(i * 7);

        if (i == max_bytes - 1) {
            // 10th byte: only bit 0 is valid for u64 (shift=63)
            if (byte > 1) return error.VarintTooLong;
        }

        result_val |= @as(u64, byte & 0x7F) << shift;
        i += 1;

        if ((byte & 0x80) == 0) {
            return .{ .value = result_val, .bytes_read = i };
        }
    }

    return error.UnexpectedEof;
}

/// Safe slice helper — validates length before slicing to prevent OOB panics from crafted messages
inline fn safeSlice(data: []const u8, pos: usize, len: u64) ![]const u8 {
    if (len > std.math.maxInt(usize)) return error.LengthOverflow;
    const length: usize = @intCast(len);
    if (length > data.len -| pos) return error.UnexpectedEof;
    return data[pos..][0..length];
}

/// Skip an unknown field based on wire type
fn skipField(wire_type: WireType, data: []const u8, pos: usize) !usize {
    var new_pos = pos;
    switch (wire_type) {
        .length_delimited => {
            const len_result = try decodeVarint(data[new_pos..]);
            new_pos += len_result.bytes_read;
            const length: usize = @intCast(len_result.value);
            if (length > data.len -| new_pos) return error.UnexpectedEof;
            new_pos += length;
        },
        .varint => {
            const val_result = try decodeVarint(data[new_pos..]);
            new_pos += val_result.bytes_read;
        },
        .fixed64 => {
            if (new_pos + 8 > data.len) return error.UnexpectedEof;
            new_pos += 8;
        },
        .fixed32 => {
            if (new_pos + 4 > data.len) return error.UnexpectedEof;
            new_pos += 4;
        },
        .start_group, .end_group => {
            // Groups are deprecated in proto3; skip by doing nothing
        },
    }
    return new_pos;
}

/// Encode a length-delimited field (strings, bytes, messages)
pub fn encodeField(field_number: u32, data: []const u8, buffer: []u8) !usize {
    var pos: usize = 0;

    // Write tag (field_number << 3 | wire_type)
    const tag = (field_number << 3) | @intFromEnum(WireType.length_delimited);
    pos += try encodeVarint(tag, buffer[pos..]);

    // Write length
    pos += try encodeVarint(data.len, buffer[pos..]);

    // Write data
    if (pos + data.len > buffer.len) return error.BufferTooSmall;
    @memcpy(buffer[pos..][0..data.len], data);
    pos += data.len;

    return pos;
}

/// Encode a varint field (int32, int64, bool, etc.)
pub fn encodeVarintField(field_number: u32, value: i64, buffer: []u8) !usize {
    var pos: usize = 0;

    // Write tag
    const tag = (field_number << 3) | @intFromEnum(WireType.varint);
    pos += try encodeVarint(tag, buffer[pos..]);

    // Write value (using zigzag encoding for signed integers)
    // Bitwise zigzag avoids overflow on minInt(i64) that arithmetic (-value) would cause
    const unsigned: u64 = @bitCast((value +% value) ^ (value >> 63));

    pos += try encodeVarint(unsigned, buffer[pos..]);

    return pos;
}

/// Encode BaseRequest
pub fn encodeBaseRequest(base: *const BaseRequest, buffer: []u8) !usize {
    var pos: usize = 0;

    // Field 1: request_id (string)
    if (base.request_id.len > 0) {
        pos += try encodeField(1, base.request_id, buffer[pos..]);
    }

    // Field 2: timestamp (int64)
    if (base.timestamp != 0) {
        pos += try encodeVarintField(2, base.timestamp, buffer[pos..]);
    }

    // Field 3: metadata (map<string, string>)
    // Maps are encoded as repeated messages with key/value fields
    var it = base.metadata.iterator();
    while (it.next()) |entry| {
        var entry_buffer: [1024]u8 = undefined;
        var entry_pos: usize = 0;

        // Key (field 1)
        entry_pos += try encodeField(1, entry.key_ptr.*, entry_buffer[entry_pos..]);

        // Value (field 2)
        entry_pos += try encodeField(2, entry.value_ptr.*, entry_buffer[entry_pos..]);

        // Write the map entry as a length-delimited field
        pos += try encodeField(3, entry_buffer[0..entry_pos], buffer[pos..]);
    }

    return pos;
}

/// Encode EchoRequest
pub fn encodeEchoRequest(request: *const EchoRequest, buffer: []u8) !usize {
    var pos: usize = 0;

    // Field 1: base (BaseRequest)
    if (request.base.request_id.len > 0 or request.base.timestamp != 0 or request.base.metadata.count() > 0) {
        var base_buffer: [2048]u8 = undefined;
        const base_len = try encodeBaseRequest(&request.base, &base_buffer);
        pos += try encodeField(1, base_buffer[0..base_len], buffer[pos..]);
    }

    // Field 2: message (string)
    if (request.message.len > 0) {
        pos += try encodeField(2, request.message, buffer[pos..]);
    }

    return pos;
}

/// Encode EchoResponse
pub fn encodeEchoResponse(response: *const EchoResponse, buffer: []u8) !usize {
    var pos: usize = 0;

    // Field 1: request_id
    if (response.request_id.len > 0) {
        pos += try encodeField(1, response.request_id, buffer[pos..]);
    }

    // Field 2: message
    if (response.message.len > 0) {
        pos += try encodeField(2, response.message, buffer[pos..]);
    }

    // Field 3: timestamp
    if (response.timestamp != 0) {
        pos += try encodeVarintField(3, response.timestamp, buffer[pos..]);
    }

    return pos;
}

/// Decode BaseRequest
pub fn decodeBaseRequest(allocator: Allocator, data: []const u8) !BaseRequest {
    var base = BaseRequest.init(allocator);
    errdefer base.deinit(allocator);

    var pos: usize = 0;

    while (pos < data.len) {
        // Read tag
        const tag_result = try decodeVarint(data[pos..]);
        pos += tag_result.bytes_read;

        const field_number = tag_result.value >> 3;
        const wire_type: WireType = @enumFromInt(@as(u3, @intCast(tag_result.value & 0x7)));

        switch (field_number) {
            1 => { // request_id
                if (wire_type != .length_delimited) return error.InvalidWireType;
                const len_result = try decodeVarint(data[pos..]);
                pos += len_result.bytes_read;

                const str_data = try safeSlice(data, pos, len_result.value);
                // Free previous value if set (duplicate field)
                if (base.request_id.len > 0) allocator.free(base.request_id);
                base.request_id = try allocator.dupe(u8, str_data);
                pos += @as(usize, @intCast(len_result.value));
            },
            2 => { // timestamp
                if (wire_type != .varint) return error.InvalidWireType;
                const val_result = try decodeVarint(data[pos..]);
                pos += val_result.bytes_read;

                // Decode zigzag
                const unsigned = val_result.value;
                base.timestamp = if ((unsigned & 1) == 0)
                    @intCast(unsigned >> 1)
                else
                    -@as(i64, @intCast((unsigned >> 1) + 1));
            },
            3 => { // metadata map entry
                if (wire_type != .length_delimited) return error.InvalidWireType;
                const len_result = try decodeVarint(data[pos..]);
                pos += len_result.bytes_read;

                const entry_data = try safeSlice(data, pos, len_result.value);
                var entry_pos: usize = 0;

                var key: []const u8 = "";
                var value: []const u8 = "";

                while (entry_pos < entry_data.len) {
                    const entry_tag = try decodeVarint(entry_data[entry_pos..]);
                    entry_pos += entry_tag.bytes_read;

                    const entry_field = entry_tag.value >> 3;
                    const entry_wire_type: WireType = @enumFromInt(@as(u3, @intCast(entry_tag.value & 0x7)));

                    if (entry_wire_type != .length_delimited) {
                        // Skip non-length-delimited inner fields
                        if (entry_wire_type == .varint) {
                            const skip = try decodeVarint(entry_data[entry_pos..]);
                            entry_pos += skip.bytes_read;
                        } else if (entry_wire_type == .fixed64) {
                            entry_pos += 8;
                        } else if (entry_wire_type == .fixed32) {
                            entry_pos += 4;
                        }
                        continue;
                    }

                    const entry_len = try decodeVarint(entry_data[entry_pos..]);
                    entry_pos += entry_len.bytes_read;

                    const field_data = try safeSlice(entry_data, entry_pos, entry_len.value);
                    if (entry_field == 1) { // key
                        key = field_data;
                    } else if (entry_field == 2) { // value
                        value = field_data;
                    }

                    entry_pos += @as(usize, @intCast(entry_len.value));
                }

                if (key.len > 0 and value.len > 0) {
                    const key_copy = try allocator.dupe(u8, key);
                    errdefer allocator.free(key_copy);
                    const value_copy = try allocator.dupe(u8, value);
                    errdefer allocator.free(value_copy);
                    try base.metadata.put(key_copy, value_copy);
                }

                pos += @as(usize, @intCast(len_result.value));
            },
            else => {
                // Skip unknown fields (all wire types)
                pos = try skipField(wire_type, data, pos);
            },
        }
    }

    return base;
}

/// Decode EchoRequest
pub fn decodeEchoRequest(allocator: Allocator, data: []const u8) !EchoRequest {
    var request = EchoRequest.init(allocator);
    errdefer request.deinit(allocator);

    var pos: usize = 0;

    while (pos < data.len) {
        const tag_result = try decodeVarint(data[pos..]);
        pos += tag_result.bytes_read;

        const field_number = tag_result.value >> 3;
        const wire_type: WireType = @enumFromInt(@as(u3, @intCast(tag_result.value & 0x7)));

        switch (field_number) {
            1 => { // base
                if (wire_type != .length_delimited) return error.InvalidWireType;
                const len_result = try decodeVarint(data[pos..]);
                pos += len_result.bytes_read;

                const sub_data = try safeSlice(data, pos, len_result.value);
                request.base.deinit(allocator);
                request.base = try decodeBaseRequest(allocator, sub_data);
                pos += @as(usize, @intCast(len_result.value));
            },
            2 => { // message
                if (wire_type != .length_delimited) return error.InvalidWireType;
                const len_result = try decodeVarint(data[pos..]);
                pos += len_result.bytes_read;

                const str_data = try safeSlice(data, pos, len_result.value);
                // Free previous value if set (duplicate field)
                if (request.message.len > 0) allocator.free(request.message);
                request.message = try allocator.dupe(u8, str_data);
                pos += @as(usize, @intCast(len_result.value));
            },
            else => {
                pos = try skipField(wire_type, data, pos);
            },
        }
    }

    return request;
}

/// Decode EchoResponse
pub fn decodeEchoResponse(allocator: Allocator, data: []const u8) !EchoResponse {
    var response = EchoResponse{};
    errdefer response.deinit(allocator);

    var pos: usize = 0;

    while (pos < data.len) {
        const tag_result = try decodeVarint(data[pos..]);
        pos += tag_result.bytes_read;

        const field_number = tag_result.value >> 3;
        const wire_type: WireType = @enumFromInt(@as(u3, @intCast(tag_result.value & 0x7)));

        switch (field_number) {
            1 => { // request_id
                if (wire_type != .length_delimited) return error.InvalidWireType;
                const len_result = try decodeVarint(data[pos..]);
                pos += len_result.bytes_read;

                const str_data = try safeSlice(data, pos, len_result.value);
                if (response.request_id.len > 0) allocator.free(response.request_id);
                response.request_id = try allocator.dupe(u8, str_data);
                pos += @as(usize, @intCast(len_result.value));
            },
            2 => { // message
                if (wire_type != .length_delimited) return error.InvalidWireType;
                const len_result = try decodeVarint(data[pos..]);
                pos += len_result.bytes_read;

                const str_data = try safeSlice(data, pos, len_result.value);
                if (response.message.len > 0) allocator.free(response.message);
                response.message = try allocator.dupe(u8, str_data);
                pos += @as(usize, @intCast(len_result.value));
            },
            3 => { // timestamp
                if (wire_type != .varint) return error.InvalidWireType;
                const val_result = try decodeVarint(data[pos..]);
                pos += val_result.bytes_read;

                // Decode zigzag
                const unsigned = val_result.value;
                response.timestamp = if ((unsigned & 1) == 0)
                    @intCast(unsigned >> 1)
                else
                    -@as(i64, @intCast((unsigned >> 1) + 1));
            },
            else => {
                pos = try skipField(wire_type, data, pos);
            },
        }
    }

    return response;
}

// ============================================================================
// gRPC Service Infrastructure
// ============================================================================

/// gRPC status codes (subset for common cases)
pub const GrpcStatus = enum(u32) {
    ok = 0,
    cancelled = 1,
    unknown = 2,
    invalid_argument = 3,
    deadline_exceeded = 4,
    not_found = 5,
    already_exists = 6,
    permission_denied = 7,
    resource_exhausted = 8,
    failed_precondition = 9,
    aborted = 10,
    out_of_range = 11,
    unimplemented = 12,
    internal = 13,
    unavailable = 14,
    data_loss = 15,
    unauthenticated = 16,
};

/// Service method definition (comptime routing info)
pub const ServiceMethod = struct {
    service_name: []const u8,
    method_name: []const u8,
    message_type: u8, // Maps to existing MESSAGE_TYPE in handlers
};

/// gRPC request wrapper (keeps existing TCP protocol)
/// Wire format: [1 byte: TYPE=250] [4 bytes: length] [Protobuf GrpcRequest]
pub const GrpcRequest = struct {
    base: BaseRequest,
    service: []const u8 = "",
    method: []const u8 = "",
    payload: []const u8 = "",

    pub fn init(allocator: Allocator) GrpcRequest {
        return .{
            .base = BaseRequest.init(allocator),
        };
    }

    pub fn deinit(self: *GrpcRequest, allocator: Allocator) void {
        self.base.deinit(allocator);
        if (self.service.len > 0) allocator.free(self.service);
        if (self.method.len > 0) allocator.free(self.method);
        if (self.payload.len > 0) allocator.free(self.payload);
    }
};

/// gRPC response wrapper
pub const GrpcResponse = struct {
    request_id: []const u8 = "",
    status_code: GrpcStatus = .ok,
    status_message: []const u8 = "",
    payload: []const u8 = "",

    pub fn deinit(self: *GrpcResponse, allocator: Allocator) void {
        if (self.request_id.len > 0) allocator.free(self.request_id);
        if (self.status_message.len > 0) allocator.free(self.status_message);
        if (self.payload.len > 0) allocator.free(self.payload);
    }
};

/// Encode GrpcRequest
pub fn encodeGrpcRequest(request: *const GrpcRequest, buffer: []u8) !usize {
    var pos: usize = 0;

    // Field 1: base (BaseRequest)
    if (request.base.request_id.len > 0 or request.base.timestamp != 0 or request.base.metadata.count() > 0) {
        var base_buffer: [2048]u8 = undefined;
        const base_len = try encodeBaseRequest(&request.base, &base_buffer);
        pos += try encodeField(1, base_buffer[0..base_len], buffer[pos..]);
    }

    // Field 2: service (string)
    if (request.service.len > 0) {
        pos += try encodeField(2, request.service, buffer[pos..]);
    }

    // Field 3: method (string)
    if (request.method.len > 0) {
        pos += try encodeField(3, request.method, buffer[pos..]);
    }

    // Field 4: payload (bytes)
    if (request.payload.len > 0) {
        pos += try encodeField(4, request.payload, buffer[pos..]);
    }

    return pos;
}

/// Decode GrpcRequest
pub fn decodeGrpcRequest(allocator: Allocator, data: []const u8) !GrpcRequest {
    var request = GrpcRequest.init(allocator);
    errdefer request.deinit(allocator);

    var pos: usize = 0;

    while (pos < data.len) {
        const tag_result = try decodeVarint(data[pos..]);
        pos += tag_result.bytes_read;

        const field_number = tag_result.value >> 3;
        const wire_type: WireType = @enumFromInt(@as(u3, @intCast(tag_result.value & 0x7)));

        switch (field_number) {
            1 => { // base
                if (wire_type != .length_delimited) return error.InvalidWireType;
                const len_result = try decodeVarint(data[pos..]);
                pos += len_result.bytes_read;

                const sub_data = try safeSlice(data, pos, len_result.value);
                request.base.deinit(allocator);
                request.base = try decodeBaseRequest(allocator, sub_data);
                pos += @as(usize, @intCast(len_result.value));
            },
            2 => { // service
                if (wire_type != .length_delimited) return error.InvalidWireType;
                const len_result = try decodeVarint(data[pos..]);
                pos += len_result.bytes_read;

                const str_data = try safeSlice(data, pos, len_result.value);
                if (request.service.len > 0) allocator.free(request.service);
                request.service = try allocator.dupe(u8, str_data);
                pos += @as(usize, @intCast(len_result.value));
            },
            3 => { // method
                if (wire_type != .length_delimited) return error.InvalidWireType;
                const len_result = try decodeVarint(data[pos..]);
                pos += len_result.bytes_read;

                const str_data = try safeSlice(data, pos, len_result.value);
                if (request.method.len > 0) allocator.free(request.method);
                request.method = try allocator.dupe(u8, str_data);
                pos += @as(usize, @intCast(len_result.value));
            },
            4 => { // payload
                if (wire_type != .length_delimited) return error.InvalidWireType;
                const len_result = try decodeVarint(data[pos..]);
                pos += len_result.bytes_read;

                const str_data = try safeSlice(data, pos, len_result.value);
                if (request.payload.len > 0) allocator.free(request.payload);
                request.payload = try allocator.dupe(u8, str_data);
                pos += @as(usize, @intCast(len_result.value));
            },
            else => {
                pos = try skipField(wire_type, data, pos);
            },
        }
    }

    return request;
}

/// Encode GrpcResponse
pub fn encodeGrpcResponse(response: *const GrpcResponse, buffer: []u8) !usize {
    var pos: usize = 0;

    // Field 1: request_id (string)
    if (response.request_id.len > 0) {
        pos += try encodeField(1, response.request_id, buffer[pos..]);
    }

    // Field 2: status_code (uint32)
    if (response.status_code != .ok) {
        const tag: u64 = (@as(u64, 2) << 3) | @as(u64, @intFromEnum(WireType.varint));
        pos += try encodeVarint(tag, buffer[pos..]);
        pos += try encodeVarint(@intFromEnum(response.status_code), buffer[pos..]);
    }

    // Field 3: status_message (string)
    if (response.status_message.len > 0) {
        pos += try encodeField(3, response.status_message, buffer[pos..]);
    }

    // Field 4: payload (bytes)
    if (response.payload.len > 0) {
        pos += try encodeField(4, response.payload, buffer[pos..]);
    }

    return pos;
}

/// Decode GrpcResponse
pub fn decodeGrpcResponse(allocator: Allocator, data: []const u8) !GrpcResponse {
    var response = GrpcResponse{};
    errdefer response.deinit(allocator);

    var pos: usize = 0;

    while (pos < data.len) {
        const tag_result = try decodeVarint(data[pos..]);
        pos += tag_result.bytes_read;

        const field_number = tag_result.value >> 3;
        const wire_type: WireType = @enumFromInt(@as(u3, @intCast(tag_result.value & 0x7)));

        switch (field_number) {
            1 => { // request_id
                if (wire_type != .length_delimited) return error.InvalidWireType;
                const len_result = try decodeVarint(data[pos..]);
                pos += len_result.bytes_read;

                const str_data = try safeSlice(data, pos, len_result.value);
                if (response.request_id.len > 0) allocator.free(response.request_id);
                response.request_id = try allocator.dupe(u8, str_data);
                pos += @as(usize, @intCast(len_result.value));
            },
            2 => { // status_code
                if (wire_type != .varint) return error.InvalidWireType;
                const val_result = try decodeVarint(data[pos..]);
                pos += val_result.bytes_read;

                response.status_code = @enumFromInt(@as(u32, @intCast(val_result.value)));
            },
            3 => { // status_message
                if (wire_type != .length_delimited) return error.InvalidWireType;
                const len_result = try decodeVarint(data[pos..]);
                pos += len_result.bytes_read;

                const str_data = try safeSlice(data, pos, len_result.value);
                if (response.status_message.len > 0) allocator.free(response.status_message);
                response.status_message = try allocator.dupe(u8, str_data);
                pos += @as(usize, @intCast(len_result.value));
            },
            4 => { // payload
                if (wire_type != .length_delimited) return error.InvalidWireType;
                const len_result = try decodeVarint(data[pos..]);
                pos += len_result.bytes_read;

                const str_data = try safeSlice(data, pos, len_result.value);
                if (response.payload.len > 0) allocator.free(response.payload);
                response.payload = try allocator.dupe(u8, str_data);
                pos += @as(usize, @intCast(len_result.value));
            },
            else => {
                pos = try skipField(wire_type, data, pos);
            },
        }
    }

    return response;
}

// Tests
test "varint encoding/decoding" {
    const allocator = std.testing.allocator;
    _ = allocator;

    var buffer: [10]u8 = undefined;

    // Test small value
    const len1 = try encodeVarint(42, &buffer);
    const result1 = try decodeVarint(buffer[0..len1]);
    try std.testing.expectEqual(@as(u64, 42), result1.value);

    // Test larger value
    const len2 = try encodeVarint(300, &buffer);
    const result2 = try decodeVarint(buffer[0..len2]);
    try std.testing.expectEqual(@as(u64, 300), result2.value);
}

test "echo request encoding/decoding" {
    const allocator = std.testing.allocator;

    // Create request
    var request = EchoRequest.init(allocator);
    defer request.deinit(allocator);

    request.base.request_id = try allocator.dupe(u8, "test-123");
    request.base.timestamp = 1234567890;
    request.message = try allocator.dupe(u8, "Hello, gRPC!");

    // Encode
    var buffer: [4096]u8 = undefined;
    const encoded_len = try encodeEchoRequest(&request, &buffer);

    // Decode
    var decoded = try decodeEchoRequest(allocator, buffer[0..encoded_len]);
    defer decoded.deinit(allocator);

    // Verify
    try std.testing.expectEqualStrings("test-123", decoded.base.request_id);
    try std.testing.expectEqual(@as(i64, 1234567890), decoded.base.timestamp);
    try std.testing.expectEqualStrings("Hello, gRPC!", decoded.message);
}

test "grpc request encoding/decoding" {
    const allocator = std.testing.allocator;

    // Create gRPC request
    var request = GrpcRequest.init(allocator);
    defer request.deinit(allocator);

    request.base.request_id = try allocator.dupe(u8, "req-456");
    request.base.timestamp = 9876543210;
    request.service = try allocator.dupe(u8, "UserService");
    request.method = try allocator.dupe(u8, "GetUser");
    request.payload = try allocator.dupe(u8, "payload_data");

    // Encode
    var buffer: [4096]u8 = undefined;
    const encoded_len = try encodeGrpcRequest(&request, &buffer);

    // Decode
    var decoded = try decodeGrpcRequest(allocator, buffer[0..encoded_len]);
    defer decoded.deinit(allocator);

    // Verify
    try std.testing.expectEqualStrings("req-456", decoded.base.request_id);
    try std.testing.expectEqual(@as(i64, 9876543210), decoded.base.timestamp);
    try std.testing.expectEqualStrings("UserService", decoded.service);
    try std.testing.expectEqualStrings("GetUser", decoded.method);
    try std.testing.expectEqualStrings("payload_data", decoded.payload);
}

test "grpc response encoding/decoding" {
    const allocator = std.testing.allocator;

    // Create gRPC response
    var response = GrpcResponse{
        .request_id = try allocator.dupe(u8, "req-789"),
        .status_code = .ok,
        .status_message = "",
        .payload = try allocator.dupe(u8, "response_data"),
    };
    defer response.deinit(allocator);

    // Encode
    var buffer: [4096]u8 = undefined;
    const encoded_len = try encodeGrpcResponse(&response, &buffer);

    // Decode
    var decoded = try decodeGrpcResponse(allocator, buffer[0..encoded_len]);
    defer decoded.deinit(allocator);

    // Verify
    try std.testing.expectEqualStrings("req-789", decoded.request_id);
    try std.testing.expectEqual(GrpcStatus.ok, decoded.status_code);
    try std.testing.expectEqualStrings("response_data", decoded.payload);
}
