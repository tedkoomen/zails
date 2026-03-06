/// Type-Safe Topic Matching System
///
/// Instead of string matching, we use:
/// 1. Compile-time topic enumeration
/// 2. Hash-based matching for performance
/// 3. Type-safe topic definitions
///
/// Performance: O(1) hash lookup instead of O(n) string comparison

const std = @import("std");

/// Topic identifier
/// Layout: [model_hash:56 bits][event_type:8 bits]
pub const TopicId = u64;

/// Event type for a topic
pub const EventKind = enum(u8) {
    created = 0,
    updated = 1,
    deleted = 2,
    custom = 255,
    wildcard = 254, // Special marker for wildcard topics
};

/// Encode topic ID from model hash and event kind
fn encodeTopicId(model_hash: u56, event_kind: EventKind) TopicId {
    const model_bits: u64 = @as(u64, model_hash) << 8;
    const event_bits: u64 = @intFromEnum(event_kind);
    return model_bits | event_bits;
}

/// Decode model hash from topic ID
fn decodeModelHash(topic_id: TopicId) u56 {
    return @intCast(topic_id >> 8);
}

/// Decode event kind from topic ID
fn decodeEventKind(topic_id: TopicId) EventKind {
    return @enumFromInt(@as(u8, @intCast(topic_id & 0xFF)));
}

/// Topic pattern for matching
pub const TopicPattern = union(enum) {
    exact: TopicId, // Exact match: "Trade.created"
    wildcard: TopicId, // Wildcard: "Trade.*" (matches all Trade events)
    any, // Match all topics

    /// Match a topic against this pattern
    pub fn matches(self: TopicPattern, topic_id: TopicId) bool {
        return switch (self) {
            .exact => |id| id == topic_id,
            .wildcard => |wildcard_id| {
                // Wildcard matches if model hash matches (ignore event type)
                const pattern_model = decodeModelHash(wildcard_id);
                const topic_model = decodeModelHash(topic_id);
                return pattern_model == topic_model;
            },
            .any => true,
        };
    }
};

/// Compile-time hash function for model name (returns 56-bit hash)
fn hashModel(comptime model: []const u8) u56 {
    // FNV-1a hash
    var hash: u64 = 0xcbf29ce484222325;
    for (model) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    // Truncate to 56 bits
    return @intCast(hash & 0x00FFFFFFFFFFFFFF);
}

/// Topic builder for model types (comptime)
pub fn Topic(comptime model_type: []const u8, comptime event_kind: EventKind) TopicId {
    const model_hash = comptime hashModel(model_type);
    return encodeTopicId(model_hash, event_kind);
}

/// Wildcard topic for all events of a model (comptime)
pub fn TopicWildcard(comptime model_type: []const u8) TopicId {
    const model_hash = comptime hashModel(model_type);
    return encodeTopicId(model_hash, .wildcard);
}

/// Topic registry - maps string topics to IDs
pub const TopicRegistry = struct {
    /// Get topic ID from string at runtime (for legacy string-based APIs)
    pub fn get(topic: []const u8) TopicId {
        // Parse "ModelName.event_type" format
        var it = std.mem.splitScalar(u8, topic, '.');
        const model_name = it.next() orelse return 0;
        const event_name = it.next() orelse return 0;

        // Hash model name
        var hash: u64 = 0xcbf29ce484222325;
        for (model_name) |byte| {
            hash ^= byte;
            hash *%= 0x100000001b3;
        }
        const model_hash: u56 = @intCast(hash & 0x00FFFFFFFFFFFFFF);

        // Parse event kind
        const event_kind: EventKind = if (std.mem.eql(u8, event_name, "created"))
            .created
        else if (std.mem.eql(u8, event_name, "updated"))
            .updated
        else if (std.mem.eql(u8, event_name, "deleted"))
            .deleted
        else if (std.mem.eql(u8, event_name, "*"))
            .wildcard
        else
            .custom;

        return encodeTopicId(model_hash, event_kind);
    }

    /// Check if a topic string matches a pattern
    pub fn matches(pattern: TopicPattern, topic: []const u8) bool {
        const topic_id = get(topic);
        return pattern.matches(topic_id);
    }
};

// Note: No predefined topics - use Topic() and TopicWildcard() generically
// Example:
//   const trade_created = Topic("Trade", .created);
//   const trade_wildcard = TopicWildcard("Trade");

// ============================================================================
// Tests
// ============================================================================

test "topic hash is deterministic" {
    const id1 = Topic("Trade", .created);
    const id2 = Topic("Trade", .created);
    try std.testing.expectEqual(id1, id2);
}

test "different topics have different ids" {
    const id1 = Topic("Trade", .created);
    const id2 = Topic("Trade", .updated);
    try std.testing.expect(id1 != id2);
}

test "different models have different ids" {
    const id1 = Topic("Trade", .created);
    const id2 = Topic("Portfolio", .created);
    try std.testing.expect(id1 != id2);
}

test "exact topic matching" {
    const trade_created = Topic("Trade", .created);
    const trade_updated = Topic("Trade", .updated);
    const portfolio_created = Topic("Portfolio", .created);

    const pattern = TopicPattern{ .exact = trade_created };

    try std.testing.expect(pattern.matches(trade_created));
    try std.testing.expect(!pattern.matches(trade_updated));
    try std.testing.expect(!pattern.matches(portfolio_created));
}

test "wildcard topic matching" {
    const trade_wildcard = TopicWildcard("Trade");
    const trade_created = Topic("Trade", .created);
    const trade_updated = Topic("Trade", .updated);
    const trade_deleted = Topic("Trade", .deleted);
    const portfolio_created = Topic("Portfolio", .created);

    const pattern = TopicPattern{ .wildcard = trade_wildcard };

    // Should match all Trade events
    try std.testing.expect(pattern.matches(trade_created));
    try std.testing.expect(pattern.matches(trade_updated));
    try std.testing.expect(pattern.matches(trade_deleted));

    // Should NOT match other models
    try std.testing.expect(!pattern.matches(portfolio_created));
}

test "any pattern matches everything" {
    const trade_created = Topic("Trade", .created);
    const portfolio_updated = Topic("Portfolio", .updated);
    const order_deleted = Topic("Order", .deleted);

    const pattern = TopicPattern{ .any = {} };

    try std.testing.expect(pattern.matches(trade_created));
    try std.testing.expect(pattern.matches(portfolio_updated));
    try std.testing.expect(pattern.matches(order_deleted));
}

test "runtime topic matching" {
    const trade_created = Topic("Trade", .created);
    const pattern = TopicPattern{ .exact = trade_created };

    try std.testing.expect(TopicRegistry.matches(pattern, "Trade.created"));
    try std.testing.expect(!TopicRegistry.matches(pattern, "Trade.updated"));
}

test "comptime vs runtime id equality" {
    const comptime_id = Topic("Trade", .created);
    const runtime_id = TopicRegistry.get("Trade.created");

    try std.testing.expectEqual(comptime_id, runtime_id);
}

test "topic encoding and decoding" {
    const trade_created = Topic("Trade", .created);

    const event_kind = decodeEventKind(trade_created);
    try std.testing.expectEqual(EventKind.created, event_kind);
}

test "wildcard event kind decoding" {
    const trade_wildcard = TopicWildcard("Trade");

    const event_kind = decodeEventKind(trade_wildcard);
    try std.testing.expectEqual(EventKind.wildcard, event_kind);
}
