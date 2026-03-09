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
        parsed: ParsedValue = .unparsed, // Pre-parsed at subscribe time for hot-path speed

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

    /// Pre-parsed numeric/bool values to avoid runtime parseInt/parseFloat on every match.
    /// Defaults to .unparsed for backward compatibility with comptime struct literals.
    pub const ParsedValue = union(enum) {
        unparsed,
        int_val: i64,
        uint_val: u64,
        float_val: f64,
        bool_val: bool,
        string_val, // No extra data needed — the string is in WhereClause.value
        parse_failed, // Value couldn't be parsed as any numeric type
    };

    /// Attempt to parse a string value into a typed ParsedValue.
    /// Called at subscribe time to amortize parsing cost.
    pub fn parseValue(value: []const u8) ParsedValue {
        // Try bool first
        if (std.mem.eql(u8, value, "true")) return .{ .bool_val = true };
        if (std.mem.eql(u8, value, "false")) return .{ .bool_val = false };

        // Try signed int
        if (std.fmt.parseInt(i64, value, 10)) |v| return .{ .int_val = v } else |_| {}

        // Try float
        if (std.fmt.parseFloat(f64, value)) |v| return .{ .float_val = v } else |_| {}

        // It's a plain string (or contains commas for in/not_in)
        return .string_val;
    }

    /// Allocation-free filter matching against typed Event fields.
    /// No JSON parsing, no heap allocation — pure value comparison.
    pub fn matches(self: *const Self, event: *const Event) bool {
        if (self.conditions.len == 0) {
            return true;
        }

        for (self.conditions) |*condition| {
            const field_value = event.getField(condition.field) orelse {
                return false;
            };

            if (!evaluateCondition(field_value, condition)) {
                return false;
            }
        }

        return true;
    }

    fn evaluateCondition(
        field_value: FieldValue,
        condition: *const WhereClause,
    ) bool {
        return switch (field_value) {
            .string => |s| evaluateStringCondition(s.slice(), condition.op, condition.value),
            .int => |i| evaluateIntCondition(i, condition),
            .uint => |u| evaluateUintCondition(u, condition),
            .float => |f| evaluateFloatCondition(f, condition),
            .boolean => |b| evaluateBoolCondition(b, condition),
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
                    const trimmed = std.mem.trim(u8, item, " ");
                    if (std.mem.eql(u8, value, trimmed)) return true;
                }
                return false;
            },
            .not_in => {
                var it = std.mem.splitScalar(u8, expected, ',');
                while (it.next()) |item| {
                    const trimmed = std.mem.trim(u8, item, " ");
                    if (std.mem.eql(u8, value, trimmed)) return false;
                }
                return true;
            },
        };
    }

    fn evaluateIntCondition(value: i64, condition: *const WhereClause) bool {
        const expected_int = switch (condition.parsed) {
            .int_val => |v| v,
            .unparsed => std.fmt.parseInt(i64, condition.value, 10) catch return false,
            else => return false,
        };
        return switch (condition.op) {
            .eq => value == expected_int,
            .ne => value != expected_int,
            .gt => value > expected_int,
            .gte => value >= expected_int,
            .lt => value < expected_int,
            .lte => value <= expected_int,
            else => false,
        };
    }

    fn evaluateUintCondition(value: u64, condition: *const WhereClause) bool {
        const expected_uint: u64 = switch (condition.parsed) {
            .uint_val => |v| v,
            .int_val => |v| if (v >= 0) @intCast(v) else return false,
            .unparsed => std.fmt.parseInt(u64, condition.value, 10) catch return false,
            else => return false,
        };
        return switch (condition.op) {
            .eq => value == expected_uint,
            .ne => value != expected_uint,
            .gt => value > expected_uint,
            .gte => value >= expected_uint,
            .lt => value < expected_uint,
            .lte => value <= expected_uint,
            else => false,
        };
    }

    /// Approximate float equality using combined absolute + relative tolerance.
    /// No heap allocation — pure stack arithmetic.
    const float_abs_epsilon: f64 = 1e-9;
    const float_rel_epsilon: f64 = 1e-9;

    fn floatApproxEqual(a: f64, b: f64) bool {
        const diff = @abs(a - b);
        if (diff <= float_abs_epsilon) return true;
        const largest = @max(@abs(a), @abs(b));
        return diff <= largest * float_rel_epsilon;
    }

    fn evaluateFloatCondition(value: f64, condition: *const WhereClause) bool {
        const expected_float = switch (condition.parsed) {
            .float_val => |v| v,
            .int_val => |v| @as(f64, @floatFromInt(v)),
            .unparsed => std.fmt.parseFloat(f64, condition.value) catch return false,
            else => return false,
        };
        return switch (condition.op) {
            .eq => floatApproxEqual(value, expected_float),
            .ne => !floatApproxEqual(value, expected_float),
            .gt => value > expected_float,
            .gte => value >= expected_float,
            .lt => value < expected_float,
            .lte => value <= expected_float,
            else => false,
        };
    }

    fn evaluateBoolCondition(value: bool, condition: *const WhereClause) bool {
        const expected_bool = switch (condition.parsed) {
            .bool_val => |v| v,
            .unparsed => std.mem.eql(u8, condition.value, "true"),
            else => return false,
        };
        return switch (condition.op) {
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

test "filter float equality with epsilon" {
    const filter = Filter{
        .conditions = &.{
            .{ .field = "price", .op = .eq, .value = "0.3" },
        },
    };

    var event = Event{
        .id = 1, .timestamp = 100, .event_type = .model_created,
        .topic = "Trade.created", .model_type = "Trade", .model_id = 1, .data = "",
    };

    // 0.1 + 0.2 is not bitwise-equal to 0.3, but should match with epsilon
    event.setField("price", .{ .float = 0.1 + 0.2 });
    try std.testing.expect(filter.matches(&event));

    // Exact 0.3 should also match
    event.setField("price", .{ .float = 0.3 });
    try std.testing.expect(filter.matches(&event));

    // A clearly different value should not match
    event.setField("price", .{ .float = 0.5 });
    try std.testing.expect(!filter.matches(&event));
}

test "filter float ne with epsilon" {
    const filter = Filter{
        .conditions = &.{
            .{ .field = "price", .op = .ne, .value = "0.3" },
        },
    };

    var event = Event{
        .id = 1, .timestamp = 100, .event_type = .model_created,
        .topic = "Trade.created", .model_type = "Trade", .model_id = 1, .data = "",
    };

    // 0.1 + 0.2 ~= 0.3, so .ne should return false
    event.setField("price", .{ .float = 0.1 + 0.2 });
    try std.testing.expect(!filter.matches(&event));

    // 0.5 != 0.3, so .ne should return true
    event.setField("price", .{ .float = 0.5 });
    try std.testing.expect(filter.matches(&event));
}

test "filter in operator trims whitespace" {
    const filter = Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .in, .value = "AAPL, GOOG, MSFT" },
        },
    };

    var event = Event{
        .id = 1, .timestamp = 100, .event_type = .model_created,
        .topic = "Trade.created", .model_type = "Trade", .model_id = 1, .data = "",
    };

    event.setField("symbol", .{ .string = FixedString.init("GOOG") });
    try std.testing.expect(filter.matches(&event));

    event.setField("symbol", .{ .string = FixedString.init("AAPL") });
    try std.testing.expect(filter.matches(&event));

    event.setField("symbol", .{ .string = FixedString.init("TSLA") });
    try std.testing.expect(!filter.matches(&event));
}

test "filter not_in operator trims whitespace" {
    const filter = Filter{
        .conditions = &.{
            .{ .field = "symbol", .op = .not_in, .value = "AAPL, GOOG" },
        },
    };

    var event = Event{
        .id = 1, .timestamp = 100, .event_type = .model_created,
        .topic = "Trade.created", .model_type = "Trade", .model_id = 1, .data = "",
    };

    event.setField("symbol", .{ .string = FixedString.init("GOOG") });
    try std.testing.expect(!filter.matches(&event));

    event.setField("symbol", .{ .string = FixedString.init("MSFT") });
    try std.testing.expect(filter.matches(&event));
}
