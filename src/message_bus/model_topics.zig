/// Entity-Owned Topic Declarations
///
/// Models and feeds declare their own topics via comptime mixins.
/// No central registry needed - topics are validated by format at compile time.
///
/// Usage:
///   const UserTopics = ModelTopics("User");
///   // UserTopics.created == "User.created"
///   // UserTopics.updated == "User.updated"
///   // UserTopics.deleted == "User.deleted"
///   // UserTopics.wildcard == "User.*"
///
///   const ItchTopics = FeedTopics("itch");
///   // ItchTopics.received == "Feed.itch"
///   // ItchTopics.wildcard == "Feed.*"

const std = @import("std");

/// Generate topic strings for a model/entity
pub fn ModelTopics(comptime name: []const u8) type {
    return struct {
        pub const created = name ++ ".created";
        pub const updated = name ++ ".updated";
        pub const deleted = name ++ ".deleted";
        pub const wildcard = name ++ ".*";
    };
}

/// Generate topic strings for a feed
pub fn FeedTopics(comptime name: []const u8) type {
    return struct {
        pub const received = "Feed." ++ name;
        pub const wildcard = "Feed.*";
    };
}

/// Custom one-off topic (for topics that don't follow ModelTopics pattern)
pub fn CustomTopic(comptime topic: []const u8) []const u8 {
    validateTopicFormat(topic);
    return topic;
}

/// Validate topic format: must be "Category.event" or "Category.*"
/// Replaces the old membership-based validateTopic()
pub fn validateTopicFormat(comptime topic: []const u8) void {
    comptime {
        // Must contain exactly one '.'
        var dot_count: usize = 0;
        var dot_pos: usize = 0;
        for (topic, 0..) |c, i| {
            if (c == '.') {
                dot_count += 1;
                dot_pos = i;
            }
        }
        if (dot_count != 1) {
            @compileError("Invalid topic format: '" ++ topic ++ "'. Must be 'Category.event' (exactly one '.')");
        }
        if (dot_pos == 0 or dot_pos == topic.len - 1) {
            @compileError("Invalid topic format: '" ++ topic ++ "'. Category and event must be non-empty");
        }
    }
}

// ====================
// Tests
// ====================

test "ModelTopics generates correct topic strings" {
    const User = ModelTopics("User");
    try std.testing.expectEqualStrings("User.created", User.created);
    try std.testing.expectEqualStrings("User.updated", User.updated);
    try std.testing.expectEqualStrings("User.deleted", User.deleted);
    try std.testing.expectEqualStrings("User.*", User.wildcard);
}

test "ModelTopics works with different entity names" {
    const Item = ModelTopics("Item");
    try std.testing.expectEqualStrings("Item.created", Item.created);

    const Order = ModelTopics("Order");
    try std.testing.expectEqualStrings("Order.created", Order.created);

    const Trade = ModelTopics("Trade");
    try std.testing.expectEqualStrings("Trade.created", Trade.created);
}

test "FeedTopics generates correct topic strings" {
    const Itch = FeedTopics("itch");
    try std.testing.expectEqualStrings("Feed.itch", Itch.received);
    try std.testing.expectEqualStrings("Feed.*", Itch.wildcard);
}

test "CustomTopic returns validated topic string" {
    const topic = CustomTopic("Item.processed");
    try std.testing.expectEqualStrings("Item.processed", topic);

    const topic2 = CustomTopic("Order.completed");
    try std.testing.expectEqualStrings("Order.completed", topic2);
}

test "validateTopicFormat accepts valid topics" {
    // These should all compile without error
    validateTopicFormat("User.created");
    validateTopicFormat("Item.updated");
    validateTopicFormat("Order.completed");
    validateTopicFormat("System.startup");
    validateTopicFormat("Feed.itch");
    validateTopicFormat("User.*");
}

// Invalid topic tests would cause compile errors, so they can't be run as normal tests.
// Uncomment to verify compile-time validation:
// test "validateTopicFormat rejects no dot" {
//     validateTopicFormat("nodot");  // compile error
// }
// test "validateTopicFormat rejects leading dot" {
//     validateTopicFormat(".leading");  // compile error
// }
// test "validateTopicFormat rejects trailing dot" {
//     validateTopicFormat("trailing.");  // compile error
// }
// test "validateTopicFormat rejects multiple dots" {
//     validateTopicFormat("too.many.dots");  // compile error
// }
