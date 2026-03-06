const std = @import("std");
const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const FieldValue = event_mod.FieldValue;
const FixedString = event_mod.FixedString;

pub const Filter = struct {
    const Self = @This();

    conditions: []const WhereClause,

    pub const WhereClause = struct {
        field: []const u8,
        op: Op,
        value: []const u8, // String representation of expected value

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

    /// Allocation-free filter matching against typed Event fields.
    /// No JSON parsing, no heap allocation — pure value comparison.
    pub fn matches(self: *const Self, event: *const Event) bool {
        if (self.conditions.len == 0) {
            return true;
        }

        for (self.conditions) |condition| {
            const field_value = event.getField(condition.field) orelse {
                return false;
            };

            if (!evaluateCondition(field_value, condition.op, condition.value)) {
                return false;
            }
        }

        return true;
    }

    fn evaluateCondition(
        field_value: FieldValue,
        op: WhereClause.Op,
        expected: []const u8,
    ) bool {
        return switch (field_value) {
            .string => |s| evaluateStringCondition(s.slice(), op, expected),
            .int => |i| evaluateIntCondition(i, op, expected),
            .uint => |u| evaluateUintCondition(u, op, expected),
            .float => |f| evaluateFloatCondition(f, op, expected),
            .boolean => |b| evaluateBoolCondition(b, op, expected),
            .none => false,
        };
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

    fn evaluateUintCondition(value: u64, op: WhereClause.Op, expected: []const u8) bool {
        const expected_uint = std.fmt.parseInt(u64, expected, 10) catch return false;
        return switch (op) {
            .eq => value == expected_uint,
            .ne => value != expected_uint,
            .gt => value > expected_uint,
            .gte => value >= expected_uint,
            .lt => value < expected_uint,
            .lte => value <= expected_uint,
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
    const filter = Filter{ .conditions = &.{} };

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "",
    };

    const result = filter.matches(&event);
    try std.testing.expect(result);
}

test "filter string equality" {
    const filter = Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .eq, .value = "AAPL" },
        },
    };

    var event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "",
    };
    event.setField("symbol", .{ .string = FixedString.init("AAPL") });
    event.setField("price", .{ .int = 150 });

    const result = filter.matches(&event);
    try std.testing.expect(result);
}

test "filter integer comparison" {
    const filter = Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gt, .value = "100" },
        },
    };

    var event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "",
    };
    event.setField("price", .{ .int = 150 });

    const result = filter.matches(&event);
    try std.testing.expect(result);
}

test "filter multiple conditions AND logic" {
    const filter = Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .eq, .value = "AAPL" },
            .{ .field = "price", .op = .gte, .value = "100" },
        },
    };

    var event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "",
    };
    event.setField("symbol", .{ .string = FixedString.init("AAPL") });
    event.setField("price", .{ .int = 150 });

    const result = filter.matches(&event);
    try std.testing.expect(result);
}

test "filter condition fails" {
    const filter = Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gt, .value = "200" },
        },
    };

    var event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "",
    };
    event.setField("price", .{ .int = 150 });

    const result = filter.matches(&event);
    try std.testing.expect(!result);
}

test "filter missing field returns false" {
    const filter = Filter{
        .conditions = &.{
            .{ .field = "missing", .op = .eq, .value = "value" },
        },
    };

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "",
    };

    const result = filter.matches(&event);
    try std.testing.expect(!result);
}

test "filter boolean comparison" {
    const filter = Filter{
        .conditions = &.{
            .{ .field = "active", .op = .eq, .value = "true" },
        },
    };

    var event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "",
    };
    event.setField("active", .{ .boolean = true });

    try std.testing.expect(filter.matches(&event));

    // Change to false - should not match
    event.setField("active", .{ .boolean = false });
    try std.testing.expect(!filter.matches(&event));
}

test "filter float comparison" {
    const filter = Filter{
        .conditions = &.{
            .{ .field = "ratio", .op = .gt, .value = "1.5" },
        },
    };

    var event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "",
    };
    event.setField("ratio", .{ .float = 2.0 });

    try std.testing.expect(filter.matches(&event));

    event.setField("ratio", .{ .float = 1.0 });
    try std.testing.expect(!filter.matches(&event));
}
