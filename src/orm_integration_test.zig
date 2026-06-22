/// Comprehensive integration tests for ORM components
/// Tests query_builder.zig, model.zig, and field_types.zig together

const std = @import("std");
const orm = @import("orm/mod.zig");

test "orm model creation with all field types" {
    const RequestMetric = orm.Model("zails_request_metrics", .{
        .id = orm.FieldDef{ .type = .UInt64, .primary_key = true },
        .timestamp = orm.FieldDef{ .type = .DateTime64 },
        .request_id = orm.FieldDef{ .type = .UUID },
        .handler_name = orm.FieldDef{ .type = .String, .low_cardinality = true },
        .latency_us = orm.FieldDef{ .type = .UInt64 },
        .status = orm.FieldDef{ .type = .String, .low_cardinality = true, .default_value = "'success'" },
        .error_message = orm.FieldDef{ .type = .String, .nullable = true },
    });

    // Test table name
    try std.testing.expectEqualStrings("zails_request_metrics", RequestMetric.getTableName());

    // Test CREATE TABLE SQL generation
    var buffer: [2048]u8 = undefined;
    const create_sql = try RequestMetric.buildCreateTableSQL(&buffer);

    // Verify SQL structure
    try std.testing.expect(std.mem.indexOf(u8, create_sql, "CREATE TABLE IF NOT EXISTS zails_request_metrics") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_sql, "id UInt64") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_sql, "timestamp DateTime64") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_sql, "request_id UUID") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_sql, "LowCardinality(String)") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_sql, "Nullable(String)") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_sql, "DEFAULT 'success'") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_sql, "ENGINE = MergeTree()") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_sql, "ORDER BY id") != null);
}

test "orm complex query building" {
    const User = orm.Model("users", .{
        .id = orm.FieldDef{ .type = .UInt64, .primary_key = true },
        .name = orm.FieldDef{ .type = .String },
        .email = orm.FieldDef{ .type = .String },
        .created_at = orm.FieldDef{ .type = .DateTime64 },
        .status = orm.FieldDef{ .type = .String, .low_cardinality = true },
    });

    // Build complex query with multiple clauses
    const fields = [_][]const u8{ "id", "name", "email", "created_at" };
    var qb = User.select(&fields);
    _ = qb.where("status", .eq, "active");
    _ = qb.where("created_at", .gt, "2024-01-01");
    _ = qb.orderBy("created_at", .desc);
    _ = qb.limit(50);
    _ = qb.offset(100);

    var buffer: [2048]u8 = undefined;
    const sql = try qb.buildSQL(&buffer);

    const expected = "SELECT id, name, email, created_at FROM users WHERE status = 'active' AND created_at > '2024-01-01' ORDER BY created_at DESC LIMIT 50 OFFSET 100";
    try std.testing.expectEqualStrings(expected, sql);
}

test "orm aggregation query" {
    const Metric = orm.Model("metrics", .{
        .id = orm.FieldDef{ .type = .UInt64, .primary_key = true },
        .handler_name = orm.FieldDef{ .type = .String },
        .latency_us = orm.FieldDef{ .type = .UInt64 },
        .timestamp = orm.FieldDef{ .type = .DateTime64 },
    });

    // Build aggregation query
    const fields = [_][]const u8{ "handler_name", "COUNT(*) as count", "AVG(latency_us) as avg_latency", "MAX(latency_us) as max_latency" };
    const group_fields = [_][]const u8{"handler_name"};

    var qb = Metric.select(&fields);
    _ = qb.where("timestamp", .gt, "2024-01-01");
    _ = qb.groupBy(&group_fields);
    _ = qb.orderBy("count", .desc);
    _ = qb.limit(10);

    var buffer: [2048]u8 = undefined;
    const sql = try qb.buildSQL(&buffer);

    try std.testing.expect(std.mem.indexOf(u8, sql, "SELECT handler_name, COUNT(*) as count") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "GROUP BY handler_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ORDER BY count DESC") != null);
}

test "orm field type declarations" {
    const test_cases = [_]struct {
        field: orm.FieldDef,
        expected: []const u8,
    }{
        .{ .field = .{ .type = .UInt64 }, .expected = "UInt64" },
        .{ .field = .{ .type = .String }, .expected = "String" },
        .{ .field = .{ .type = .String, .nullable = true }, .expected = "Nullable(String)" },
        .{ .field = .{ .type = .String, .low_cardinality = true }, .expected = "LowCardinality(String)" },
        .{ .field = .{ .type = .DateTime64 }, .expected = "DateTime64" },
        .{ .field = .{ .type = .UUID }, .expected = "UUID" },
        .{ .field = .{ .type = .Float64 }, .expected = "Float64" },
    };

    var buffer: [128]u8 = undefined;
    for (test_cases) |case| {
        const decl = try case.field.getTypeDecl(&buffer);
        try std.testing.expectEqualStrings(case.expected, decl);
    }
}

test "orm query builder with IN operator" {
    const Post = orm.Model("posts", .{
        .id = orm.FieldDef{ .type = .UInt64, .primary_key = true },
        .title = orm.FieldDef{ .type = .String },
        .status = orm.FieldDef{ .type = .String },
    });

    var qb = Post.where("status", .in, "'published', 'draft'");
    _ = qb.orderBy("id", .desc);

    var buffer: [1024]u8 = undefined;
    const sql = try qb.buildSQL(&buffer);

    try std.testing.expect(std.mem.indexOf(u8, sql, "WHERE status IN ('published', 'draft')") != null);
}

test "orm query builder with LIKE operator" {
    const Article = orm.Model("articles", .{
        .id = orm.FieldDef{ .type = .UInt64, .primary_key = true },
        .title = orm.FieldDef{ .type = .String },
        .content = orm.FieldDef{ .type = .String },
    });

    var qb = Article.where("title", .like, "%search term%");

    var buffer: [1024]u8 = undefined;
    const sql = try qb.buildSQL(&buffer);

    try std.testing.expect(std.mem.indexOf(u8, sql, "WHERE title LIKE '%search term%'") != null);
}

test "orm multiple where clauses with different operators" {
    const Order = orm.Model("orders", .{
        .id = orm.FieldDef{ .type = .UInt64, .primary_key = true },
        .user_id = orm.FieldDef{ .type = .UInt64 },
        .total = orm.FieldDef{ .type = .Float64 },
        .status = orm.FieldDef{ .type = .String },
        .created_at = orm.FieldDef{ .type = .DateTime64 },
    });

    var qb = Order.where("status", .ne, "cancelled");
    _ = qb.where("total", .gte, "100.00");
    _ = qb.where("created_at", .lt, "2024-12-31");
    _ = qb.orderBy("created_at", .desc);

    var buffer: [2048]u8 = undefined;
    const sql = try qb.buildSQL(&buffer);

    try std.testing.expect(std.mem.indexOf(u8, sql, "status != 'cancelled'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "total >= '100.00'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "created_at < '2024-12-31'") != null);
}

test "orm empty query (select all)" {
    const Product = orm.Model("products", .{
        .id = orm.FieldDef{ .type = .UInt64, .primary_key = true },
        .name = orm.FieldDef{ .type = .String },
        .price = orm.FieldDef{ .type = .Float64 },
    });

    const QB = orm.QueryBuilder(Product);
    var qb = QB.init("products");

    var buffer: [1024]u8 = undefined;
    const sql = try qb.buildSQL(&buffer);

    try std.testing.expectEqualStrings("SELECT * FROM products", sql);
}

test "orm query builder max capacity" {
    const Test = orm.Model("test", .{
        .id = orm.FieldDef{ .type = .UInt64, .primary_key = true },
    });

    const QB = orm.QueryBuilder(Test);
    var qb = QB.init("test");

    // Add maximum number of WHERE clauses (16)
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        _ = qb.where("field", .eq, "value");
    }

    // Verify 16 clauses were added
    try std.testing.expectEqual(@as(usize, 16), qb.where_count);

    // Add one more (should be ignored due to capacity)
    _ = qb.where("extra", .eq, "ignored");
    try std.testing.expectEqual(@as(usize, 16), qb.where_count);
}
