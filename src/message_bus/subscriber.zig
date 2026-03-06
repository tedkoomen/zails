const std = @import("std");
const Allocator = std.mem.Allocator;
const Event = @import("../event.zig").Event;
const Filter = @import("filter.zig").Filter;

pub const HandlerFn = *const fn (event: *const Event, allocator: Allocator) void;

pub const Subscription = struct {
    id: SubscriptionId,
    topic: []const u8,
    filter: Filter,
    handler: HandlerFn,
    created_at: i64,

    pub fn matchesTopic(self: *const Subscription, event_topic: []const u8) bool {
        if (std.mem.eql(u8, self.topic, event_topic)) {
            return true;
        }

        if (std.mem.endsWith(u8, self.topic, ".*")) {
            const prefix = self.topic[0 .. self.topic.len - 2];
            if (std.mem.startsWith(u8, event_topic, prefix)) {
                if (event_topic.len > prefix.len and event_topic[prefix.len] == '.') {
                    return true;
                }
            }
        }

        return false;
    }
};

pub const SubscriptionId = u64;

var next_subscription_id = std.atomic.Value(u64).init(1);

pub fn generateSubscriptionId() SubscriptionId {
    return next_subscription_id.fetchAdd(1, .monotonic);
}

test "exact topic match" {
    const sub = Subscription{
        .id = 1,
        .topic = "Trade.created",
        .filter = Filter{ .conditions = &.{} },
        .handler = undefined,
        .created_at = 0,
    };

    try std.testing.expect(sub.matchesTopic("Trade.created"));
    try std.testing.expect(!sub.matchesTopic("Trade.updated"));
    try std.testing.expect(!sub.matchesTopic("Portfolio.created"));
}

test "wildcard topic match" {
    const sub = Subscription{
        .id = 1,
        .topic = "Trade.*",
        .filter = Filter{ .conditions = &.{} },
        .handler = undefined,
        .created_at = 0,
    };

    try std.testing.expect(sub.matchesTopic("Trade.created"));
    try std.testing.expect(sub.matchesTopic("Trade.updated"));
    try std.testing.expect(sub.matchesTopic("Trade.deleted"));
    try std.testing.expect(!sub.matchesTopic("Portfolio.created"));
    try std.testing.expect(!sub.matchesTopic("Trade")); // No dot after prefix
}

test "subscription id generation" {
    const id1 = generateSubscriptionId();
    const id2 = generateSubscriptionId();
    const id3 = generateSubscriptionId();

    try std.testing.expect(id1 < id2);
    try std.testing.expect(id2 < id3);
}
