const std = @import("std");
const Allocator = std.mem.Allocator;
const Event = @import("../event.zig").Event;

pub const Filter = struct {
    const Self = @This();

    conditions: []const WhereClause,

    pub const WhereClause = struct {
        field: []const u8,
        op: Op,
        value: []const u8, // String representation of value

        pub const Op = enum {
            eq,
            ne,
            gt,
            gte,
            lt,
            lte,
            like,
            in,
            not_in,
        };
    };

    pub fn matches(
        self: *const Self,
        event: *const Event,
        allocator: Allocator,
    ) !bool {
        if (self.conditions.len == 0) {
            return true;
        }

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            event.data,
            .{},
        ) catch |err| {
            std.log.warn("Filter: JSON parse error: {}", .{err});
            return false;
        };
        defer parsed.deinit();

        for (self.conditions) |condition| {
            const field_value = getNestedField(parsed.value, condition.field) orelse {
                std.log.debug("Filter: field '{s}' not found in event data", .{condition.field});
                return false;
            };

            const result = evaluateCondition(field_value, condition.op, condition.value);
            std.log.debug("Filter: field='{s}' op={} value='{s}' result={}", .{
                condition.field,
                condition.op,
                condition.value,
                result,
            });

            if (!result) {
                return false;
            }
        }

        return true;
    }

    fn getNestedField(value: std.json.Value, field_path: []const u8) ?std.json.Value {
        var current = value;
        var it = std.mem.splitScalar(u8, field_path, '.');

        while (it.next()) |part| {
            switch (current) {
                .object => |obj| {
                    current = obj.get(part) orelse return null;
                },
                else => return null,
            }
        }

        return current;
    }

    fn evaluateCondition(
        field_value: std.json.Value,
        op: WhereClause.Op,
        expected: []const u8,
    ) bool {
        switch (field_value) {
            .string => |s| return evaluateStringCondition(s, op, expected),
            .integer => |i| return evaluateIntCondition(i, op, expected),
            .float => |f| return evaluateFloatCondition(f, op, expected),
            .bool => |b| return evaluateBoolCondition(b, op, expected),
            .null => return false,
            else => return false,
        }
    }

    fn evaluateStringCondition(value: []const u8, op: WhereClause.Op, expected: []const u8) bool {
        return switch (op) {
            .eq => std.mem.eql(u8, value, expected),
            .ne => !std.mem.eql(u8, value, expected),
            .gt => std.mem.order(u8, value, expected) == .gt,
            .gte => {
                const order = std.mem.order(u8, value, expected);
                return order == .gt or order == .eq;
            },
            .lt => std.mem.order(u8, value, expected) == .lt,
            .lte => {
                const order = std.mem.order(u8, value, expected);
                return order == .lt or order == .eq;
            },
            .like => std.mem.indexOf(u8, value, expected) != null,
            .in => {
                var it = std.mem.splitScalar(u8, expected, ',');
                while (it.next()) |item| {
                    if (std.mem.eql(u8, value, item)) return true;
                }
                return false;
            },
            .not_in => {
                var it = std.mem.splitScalar(u8, expected, ',');
                while (it.next()) |item| {
                    if (std.mem.eql(u8, value, item)) return false;
                }
                return true;
            },
        };
    }

    fn evaluateIntCondition(value: i64, op: WhereClause.Op, expected: []const u8) bool {
        const expected_int = std.fmt.parseInt(i64, expected, 10) catch return false;
        return switch (op) {
            .eq => value == expected_int,
            .ne => value != expected_int,
            .gt => value > expected_int,
            .gte => value >= expected_int,
            .lt => value < expected_int,
            .lte => value <= expected_int,
            else => false,
        };
    }

    fn evaluateFloatCondition(value: f64, op: WhereClause.Op, expected: []const u8) bool {
        const expected_float = std.fmt.parseFloat(f64, expected) catch return false;
        return switch (op) {
            .eq => value == expected_float,
            .ne => value != expected_float,
            .gt => value > expected_float,
            .gte => value >= expected_float,
            .lt => value < expected_float,
            .lte => value <= expected_float,
            else => false,
        };
    }

    fn evaluateBoolCondition(value: bool, op: WhereClause.Op, expected: []const u8) bool {
        const expected_bool = std.mem.eql(u8, expected, "true");
        return switch (op) {
            .eq => value == expected_bool,
            .ne => value != expected_bool,
            else => false,
        };
    }
};

test "filter empty conditions matches all" {
    const allocator = std.testing.allocator;

    const filter = Filter{ .conditions = &.{} };

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{\"price\":150}",
    };

    const result = try filter.matches(&event, allocator);
    try std.testing.expect(result);
}

test "filter string equality" {
    const allocator = std.testing.allocator;

    const filter = Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .eq, .value = "AAPL" },
        },
    };

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{\"symbol\":\"AAPL\",\"price\":150}",
    };

    const result = try filter.matches(&event, allocator);
    try std.testing.expect(result);
}

test "filter integer comparison" {
    const allocator = std.testing.allocator;

    const filter = Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gt, .value = "100" },
        },
    };

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{\"symbol\":\"AAPL\",\"price\":150}",
    };

    const result = try filter.matches(&event, allocator);
    try std.testing.expect(result);
}

test "filter multiple conditions AND logic" {
    const allocator = std.testing.allocator;

    const filter = Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .eq, .value = "AAPL" },
            .{ .field = "price", .op = .gte, .value = "100" },
        },
    };

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{\"symbol\":\"AAPL\",\"price\":150}",
    };

    const result = try filter.matches(&event, allocator);
    try std.testing.expect(result);
}

test "filter condition fails" {
    const allocator = std.testing.allocator;

    const filter = Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gt, .value = "200" },
        },
    };

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{\"symbol\":\"AAPL\",\"price\":150}",
    };

    const result = try filter.matches(&event, allocator);
    try std.testing.expect(!result);
}
