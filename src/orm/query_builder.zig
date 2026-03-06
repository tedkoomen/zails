/// ClickHouse Query Builder - Fluent API for query construction
/// Optimized for ClickHouse semantics (analytics-first, not OLTP)
/// Tiger Style: errors as values, stack-allocated builders

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Escape a string value for safe inclusion in SQL (prevents SQL injection)
/// Escapes single quotes by doubling them, and escapes backslashes
fn escapeSQL(writer: anytype, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '\'' => try writer.writeAll("''"),
            '\\' => try writer.writeAll("\\\\"),
            0 => try writer.writeAll("\\0"),
            else => try writer.writeByte(c),
        }
    }
}

/// Comparison operators for WHERE clauses
pub const Op = enum {
    eq, // =
    ne, // !=
    gt, // >
    gte, // >=
    lt, // <
    lte, // <=
    like, // LIKE
    in, // IN
    not_in, // NOT IN

    pub fn toString(self: Op) []const u8 {
        return switch (self) {
            .eq => "=",
            .ne => "!=",
            .gt => ">",
            .gte => ">=",
            .lt => "<",
            .lte => "<=",
            .like => "LIKE",
            .in => "IN",
            .not_in => "NOT IN",
        };
    }
};

/// Sort direction
pub const Direction = enum {
    asc,
    desc,

    pub fn toString(self: Direction) []const u8 {
        return switch (self) {
            .asc => "ASC",
            .desc => "DESC",
        };
    }
};

/// WHERE clause representation
pub const WhereClause = struct {
    field: []const u8,
    op: Op,
    value: []const u8, // Stored as string (caller must format)
};

/// ORDER BY clause
pub const OrderBy = struct {
    field: []const u8,
    direction: Direction,
};

/// Query builder for a specific model type
/// Stack-allocated, no heap allocations in builder itself
pub fn QueryBuilder(comptime Model: type) type {
    return struct {
        const Self = @This();

        const MAX_WHERE_CLAUSES = 16;
        const MAX_SELECT_FIELDS = 32;
        const MAX_GROUP_BY_FIELDS = 8;

        table_name: []const u8,
        select_fields: [MAX_SELECT_FIELDS][]const u8,
        select_count: usize,
        where_clauses: [MAX_WHERE_CLAUSES]WhereClause,
        where_count: usize,
        order_by_field: ?[]const u8,
        order_by_direction: Direction,
        limit_val: ?usize,
        offset_val: ?usize,
        group_by_fields: [MAX_GROUP_BY_FIELDS][]const u8,
        group_by_count: usize,

        /// Initialize query builder for a table
        pub fn init(table: []const u8) Self {
            return .{
                .table_name = table,
                .select_fields = undefined,
                .select_count = 0,
                .where_clauses = undefined,
                .where_count = 0,
                .order_by_field = null,
                .order_by_direction = .asc,
                .limit_val = null,
                .offset_val = null,
                .group_by_fields = undefined,
                .group_by_count = 0,
            };
        }

        /// Select specific fields (chainable)
        pub fn select(self: *Self, fields: []const []const u8) *Self {
            for (fields) |field| {
                if (self.select_count < MAX_SELECT_FIELDS) {
                    self.select_fields[self.select_count] = field;
                    self.select_count += 1;
                } else {
                    std.log.warn("QueryBuilder: MAX_SELECT_FIELDS ({d}) exceeded, field dropped", .{MAX_SELECT_FIELDS});
                }
            }
            return self;
        }

        /// Add WHERE clause (chainable)
        pub fn where(self: *Self, field: []const u8, op: Op, value: []const u8) *Self {
            if (self.where_count < MAX_WHERE_CLAUSES) {
                self.where_clauses[self.where_count] = .{
                    .field = field,
                    .op = op,
                    .value = value,
                };
                self.where_count += 1;
            } else {
                std.log.warn("QueryBuilder: MAX_WHERE_CLAUSES ({d}) exceeded, clause dropped: {s}", .{ MAX_WHERE_CLAUSES, field });
            }
            return self;
        }

        /// Add ORDER BY clause (chainable)
        pub fn orderBy(self: *Self, field: []const u8, direction: Direction) *Self {
            self.order_by_field = field;
            self.order_by_direction = direction;
            return self;
        }

        /// Add LIMIT clause (chainable)
        pub fn limit(self: *Self, n: usize) *Self {
            self.limit_val = n;
            return self;
        }

        /// Add OFFSET clause (chainable)
        pub fn offset(self: *Self, n: usize) *Self {
            self.offset_val = n;
            return self;
        }

        /// Add GROUP BY clause (chainable)
        pub fn groupBy(self: *Self, fields: []const []const u8) *Self {
            for (fields) |field| {
                if (self.group_by_count < MAX_GROUP_BY_FIELDS) {
                    self.group_by_fields[self.group_by_count] = field;
                    self.group_by_count += 1;
                } else {
                    std.log.warn("QueryBuilder: MAX_GROUP_BY_FIELDS ({d}) exceeded, field dropped", .{MAX_GROUP_BY_FIELDS});
                }
            }
            return self;
        }

        /// Build SQL query string
        pub fn buildSQL(self: *const Self, buffer: []u8) ![]const u8 {
            var fbs = std.io.fixedBufferStream(buffer);
            const writer = fbs.writer();

            // SELECT clause
            try writer.writeAll("SELECT ");

            if (self.select_count > 0) {
                for (self.select_fields[0..self.select_count], 0..) |field, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(field);
                }
            } else {
                try writer.writeAll("*");
            }

            // FROM clause
            try writer.writeAll(" FROM ");
            try writer.writeAll(self.table_name);

            // WHERE clause
            if (self.where_count > 0) {
                try writer.writeAll(" WHERE ");
                try writeWhereClauses(writer, self.where_clauses[0..self.where_count]);
            }

            // GROUP BY clause
            if (self.group_by_count > 0) {
                try writer.writeAll(" GROUP BY ");
                for (self.group_by_fields[0..self.group_by_count], 0..) |field, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(field);
                }
            }

            // ORDER BY clause
            if (self.order_by_field) |field| {
                try writer.writeAll(" ORDER BY ");
                try writer.writeAll(field);
                try writer.writeAll(" ");
                try writer.writeAll(self.order_by_direction.toString());
            }

            // LIMIT clause
            if (self.limit_val) |n| {
                try writer.print(" LIMIT {d}", .{n});
            }

            // OFFSET clause
            if (self.offset_val) |n| {
                try writer.print(" OFFSET {d}", .{n});
            }

            return fbs.getWritten();
        }

        /// Execute query (to be implemented with actual ClickHouse client)
        pub fn execute(self: *const Self, allocator: Allocator) ![]Model {
            _ = self;
            _ = allocator;
            // TODO: Implement actual query execution
            return &[_]Model{};
        }

        /// Count records matching query
        pub fn count(self: *Self, allocator: Allocator) !u64 {
            _ = allocator;

            // Build COUNT(*) query
            var buffer: [4096]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buffer);
            const writer = fbs.writer();

            try writer.writeAll("SELECT COUNT(*) FROM ");
            try writer.writeAll(self.table_name);

            if (self.where_count > 0) {
                try writer.writeAll(" WHERE ");
                try writeWhereClauses(writer, self.where_clauses[0..self.where_count]);
            }

            // TODO: Execute query and parse result
            return 0;
        }

        /// Shared WHERE clause writer (used by both buildSQL and count)
        fn writeWhereClauses(writer: anytype, clauses: []const WhereClause) !void {
            for (clauses, 0..) |clause, i| {
                if (i > 0) try writer.writeAll(" AND ");

                try writer.writeAll(clause.field);
                try writer.writeAll(" ");
                try writer.writeAll(clause.op.toString());
                try writer.writeAll(" ");

                // Handle IN operator: individually escape each value
                if (clause.op == .in or clause.op == .not_in) {
                    try writer.writeAll("(");
                    var it = std.mem.splitScalar(u8, clause.value, ',');
                    var first = true;
                    while (it.next()) |item| {
                        if (!first) try writer.writeAll(", ");
                        first = false;
                        try writer.writeAll("'");
                        try escapeSQL(writer, std.mem.trim(u8, item, " "));
                        try writer.writeAll("'");
                    }
                    try writer.writeAll(")");
                } else {
                    // Quote and escape string values (SQL injection prevention)
                    try writer.writeAll("'");
                    try escapeSQL(writer, clause.value);
                    try writer.writeAll("'");
                }
            }
        }
    };
}

// Tests
test "query builder basic select" {
    const MockModel = struct {
        id: u64,
        name: []const u8,
    };

    const QB = QueryBuilder(MockModel);
    var qb = QB.init("users");

    var buffer: [1024]u8 = undefined;
    const sql = try qb.buildSQL(&buffer);

    try std.testing.expectEqualStrings("SELECT * FROM users", sql);
}

test "query builder with where clause" {
    const MockModel = struct {
        id: u64,
        status: []const u8,
    };

    const QB = QueryBuilder(MockModel);
    var qb = QB.init("requests");
    _ = qb.where("status", .eq, "active");
    _ = qb.where("priority", .gt, "5");

    var buffer: [1024]u8 = undefined;
    const sql = try qb.buildSQL(&buffer);

    try std.testing.expectEqualStrings(
        "SELECT * FROM requests WHERE status = 'active' AND priority > '5'",
        sql,
    );
}

test "query builder with select, where, order by, limit" {
    const MockModel = struct {
        id: u64,
        name: []const u8,
        created_at: i64,
    };

    const QB = QueryBuilder(MockModel);
    var qb = QB.init("posts");

    const fields = [_][]const u8{ "id", "name", "created_at" };
    _ = qb.select(&fields);
    _ = qb.where("status", .eq, "published");
    _ = qb.orderBy("created_at", .desc);
    _ = qb.limit(10);

    var buffer: [1024]u8 = undefined;
    const sql = try qb.buildSQL(&buffer);

    try std.testing.expectEqualStrings(
        "SELECT id, name, created_at FROM posts WHERE status = 'published' ORDER BY created_at DESC LIMIT 10",
        sql,
    );
}

test "query builder with group by" {
    const MockModel = struct {
        handler: []const u8,
        count: u64,
    };

    const QB = QueryBuilder(MockModel);
    var qb = QB.init("metrics");

    const select_fields = [_][]const u8{ "handler_name", "COUNT(*) as count" };
    const group_fields = [_][]const u8{"handler_name"};

    _ = qb.select(&select_fields);
    _ = qb.groupBy(&group_fields);
    _ = qb.orderBy("count", .desc);

    var buffer: [1024]u8 = undefined;
    const sql = try qb.buildSQL(&buffer);

    try std.testing.expectEqualStrings(
        "SELECT handler_name, COUNT(*) as count FROM metrics GROUP BY handler_name ORDER BY count DESC",
        sql,
    );
}

test "query builder IN clause escapes values" {
    const MockModel = struct {
        id: u64,
        status: []const u8,
    };

    const QB = QueryBuilder(MockModel);
    var qb = QB.init("users");
    _ = qb.where("id", .in, "1, 2, 3");

    var buffer: [1024]u8 = undefined;
    const sql = try qb.buildSQL(&buffer);

    // Values should be individually quoted and escaped
    try std.testing.expectEqualStrings(
        "SELECT * FROM users WHERE id IN ('1', '2', '3')",
        sql,
    );
}

test "query builder SQL injection prevention" {
    const MockModel = struct {
        id: u64,
        name: []const u8,
    };

    const QB = QueryBuilder(MockModel);
    var qb = QB.init("users");
    _ = qb.where("name", .eq, "O'Brien");

    var buffer: [1024]u8 = undefined;
    const sql = try qb.buildSQL(&buffer);

    // Single quote should be escaped
    try std.testing.expectEqualStrings(
        "SELECT * FROM users WHERE name = 'O''Brien'",
        sql,
    );
}

test "query builder NOT IN clause" {
    const MockModel = struct {
        id: u64,
    };

    const QB = QueryBuilder(MockModel);
    var qb = QB.init("items");
    _ = qb.where("status", .not_in, "deleted, archived");

    var buffer: [1024]u8 = undefined;
    const sql = try qb.buildSQL(&buffer);

    try std.testing.expectEqualStrings(
        "SELECT * FROM items WHERE status NOT IN ('deleted', 'archived')",
        sql,
    );
}
