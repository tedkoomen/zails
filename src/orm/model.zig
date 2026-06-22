/// ORM Model - ActiveRecord-like base model for ClickHouse
/// Provides .all(), .find(), .where(), .create() methods
/// Optimized for ClickHouse analytics workloads
const std = @import("std");
const Allocator = std.mem.Allocator;
const query_builder = @import("query_builder.zig");
const field_types = @import("field_types.zig");

fn isIdentifierStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentifierChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isValidIdentifierPath(identifier: []const u8) bool {
    if (identifier.len == 0) return false;

    var at_segment_start = true;
    var saw_segment_char = false;
    for (identifier) |c| {
        if (c == '.') {
            if (at_segment_start or !saw_segment_char) return false;
            at_segment_start = true;
            saw_segment_char = false;
            continue;
        }

        if (at_segment_start) {
            if (!isIdentifierStart(c)) return false;
            at_segment_start = false;
        } else if (!isIdentifierChar(c)) {
            return false;
        }
        saw_segment_char = true;
    }

    return saw_segment_char;
}

fn writeIdentifier(writer: anytype, identifier: []const u8) !void {
    if (!isValidIdentifierPath(identifier)) return error.InvalidIdentifier;
    try writer.writeAll(identifier);
}

/// Model trait - provides ActiveRecord-like interface
pub fn Model(comptime table_name: []const u8, comptime fields: anytype) type {
    // Validate field definitions at compile time
    comptime {
        const fields_info = @typeInfo(@TypeOf(fields));
        if (fields_info != .@"struct") {
            @compileError("fields must be a struct");
        }
        if (!isValidIdentifierPath(table_name)) {
            @compileError("table_name must be a valid SQL identifier path");
        }
        for (fields_info.@"struct".fields) |field| {
            if (!isValidIdentifierPath(field.name)) {
                @compileError("model field name must be a valid SQL identifier");
            }
        }
    }

    return struct {
        const Self = @This();
        const QueryBuilder = query_builder.QueryBuilder(Self);

        // Auto-generate struct fields from field definitions
        // For now, we'll use a simple approach where the model
        // is defined by the user and this provides query methods

        /// Get all records
        pub fn all(allocator: Allocator) ![]Self {
            var qb = QueryBuilder.init(table_name);
            return try qb.execute(allocator);
        }

        /// Find record by ID
        pub fn find(allocator: Allocator, id: u64) !?Self {
            var qb = QueryBuilder.init(table_name);
            var id_buffer: [32]u8 = undefined;
            const id_str = try std.fmt.bufPrint(&id_buffer, "{d}", .{id});

            _ = qb.where("id", .eq, id_str);
            _ = qb.limit(1);

            const results = try qb.execute(allocator);
            defer allocator.free(results);
            if (results.len > 0) {
                return results[0];
            }
            return null;
        }

        /// Start a query builder chain
        pub fn where(field: []const u8, op: query_builder.Op, value: []const u8) QueryBuilder {
            var qb = QueryBuilder.init(table_name);
            _ = qb.where(field, op, value);
            return qb;
        }

        /// Select specific fields
        pub fn select(fields_list: []const []const u8) QueryBuilder {
            var qb = QueryBuilder.init(table_name);
            _ = qb.select(fields_list);
            return qb;
        }

        /// Create new record (insert)
        pub fn create(self: Self, allocator: Allocator) !void {
            _ = self;
            _ = allocator;
            return error.NotImplemented;
        }

        /// Build CREATE TABLE statement
        pub fn buildCreateTableSQL(buffer: []u8) ![]const u8 {
            var fbs = std.io.fixedBufferStream(buffer);
            const writer = fbs.writer();

            try writer.writeAll("CREATE TABLE IF NOT EXISTS ");
            try writeIdentifier(writer, table_name);
            try writer.writeAll(" (\n");

            // Iterate over field definitions
            const fields_info = @typeInfo(@TypeOf(fields)).@"struct";
            inline for (fields_info.fields, 0..) |field, i| {
                if (i > 0) try writer.writeAll(",\n");

                const field_def = @field(fields, field.name);

                try writer.writeAll("  ");
                try writeIdentifier(writer, field.name);
                try writer.writeAll(" ");

                var type_buffer: [128]u8 = undefined;
                const type_decl = try field_def.getTypeDecl(&type_buffer);
                try writer.writeAll(type_decl);

                if (field_def.default_value) |default| {
                    try writer.writeAll(" DEFAULT ");
                    try writer.writeAll(default);
                }
            }

            try writer.writeAll("\n) ENGINE = MergeTree()\n");

            // Find primary key
            inline for (fields_info.fields) |field| {
                const field_def = @field(fields, field.name);
                if (field_def.primary_key) {
                    try writer.writeAll("ORDER BY ");
                    try writeIdentifier(writer, field.name);
                    break;
                }
            }

            return fbs.getWritten();
        }

        /// Get table name (comptime)
        pub fn getTableName() []const u8 {
            return table_name;
        }
    };
}

// Tests
test "model basic usage" {
    const RequestMetric = Model("zails_request_metrics", .{
        .id = field_types.FieldDef{ .type = .UInt64, .primary_key = true },
        .timestamp = field_types.FieldDef{ .type = .DateTime64 },
        .request_id = field_types.FieldDef{ .type = .UUID },
        .handler_name = field_types.FieldDef{ .type = .String, .low_cardinality = true },
        .latency_us = field_types.FieldDef{ .type = .UInt64 },
        .status = field_types.FieldDef{ .type = .String, .low_cardinality = true, .default_value = "'success'" },
    });

    // Test table name
    try std.testing.expectEqualStrings("zails_request_metrics", RequestMetric.getTableName());

    // Test CREATE TABLE generation
    var buffer: [2048]u8 = undefined;
    const create_sql = try RequestMetric.buildCreateTableSQL(&buffer);

    // Verify it contains expected elements
    try std.testing.expect(std.mem.indexOf(u8, create_sql, "CREATE TABLE IF NOT EXISTS zails_request_metrics") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_sql, "id UInt64") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_sql, "LowCardinality(String)") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_sql, "ORDER BY id") != null);
}

test "model query builder integration" {
    const User = Model("users", .{
        .id = field_types.FieldDef{ .type = .UInt64, .primary_key = true },
        .name = field_types.FieldDef{ .type = .String },
        .email = field_types.FieldDef{ .type = .String },
    });

    // Test query builder chaining
    var qb = User.where("status", .eq, "active");
    _ = qb.orderBy("created_at", .desc);
    _ = qb.limit(10);

    var buffer: [1024]u8 = undefined;
    const sql = try qb.buildSQL(&buffer);

    try std.testing.expect(std.mem.indexOf(u8, sql, "FROM users") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "WHERE status = 'active'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "LIMIT 10") != null);
}
