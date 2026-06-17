const std = @import("std");
const Allocator = std.mem.Allocator;
const Event = @import("../event.zig").Event;
const Filter = @import("filter.zig").Filter;
const topic_matcher = @import("topic_matcher.zig");

pub const HandlerFn = *const fn (event: *const Event, allocator: Allocator) void;

pub const Subscription = struct {
    id: SubscriptionId,
    topic: []const u8,
    filter: Filter,
    handler: HandlerFn,
    created_at: i64,
    topic_pattern: topic_matcher.TopicPattern = .any, // Computed at subscribe time

    /// Match using pre-computed hash-based topic pattern (O(1)).
    /// Falls back to string match if topic_pattern is .any and topic isn't "*",
    /// which means the pattern was never computed (e.g. test-constructed subscriptions
    /// or legacy code). True .any (topic == "*") matches everything.
    pub fn matchesTopic(self: *const Subscription, event_topic: []const u8) bool {
        // If topic_pattern is .any but the topic string isn't "*", the pattern
        // was never computed — fall through to string matching.
        if (self.topic_pattern == .any and !std.mem.eql(u8, self.topic, "*")) {
            return self.matchesTopicString(event_topic);
        }

        // Use hash-based O(1) matching via pre-computed topic pattern
        const event_id = topic_matcher.TopicRegistry.get(event_topic);
        if (event_id != 0) {
            return self.topic_pattern.matches(event_id);
        }

        // Fallback: string-based matching for non-standard topic formats
        return self.matchesTopicString(event_topic);
    }

    /// Legacy string-based topic matching (used as fallback)
    fn matchesTopicString(self: *const Subscription, event_topic: []const u8) bool {
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

    /// Compute the TopicPattern from a topic string.
    /// Called at subscribe time to avoid runtime parsing on every match.
    pub fn computeTopicPattern(topic: []const u8) topic_matcher.TopicPattern {
        if (std.mem.eql(u8, topic, "*")) {
            return .any;
        }
        if (std.mem.endsWith(u8, topic, ".*")) {
            const wildcard_id = topic_matcher.TopicRegistry.get(topic);
            return .{ .wildcard = wildcard_id };
        }
        const exact_id = topic_matcher.TopicRegistry.get(topic);
        return .{ .exact = exact_id };
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
