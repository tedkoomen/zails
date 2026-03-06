const std = @import("std");
const Allocator = std.mem.Allocator;
const Event = @import("../event.zig").Event;
const Filter = @import("filter.zig").Filter;
const subscriber = @import("subscriber.zig");
const Subscription = subscriber.Subscription;
const SubscriptionId = subscriber.SubscriptionId;
const HandlerFn = subscriber.HandlerFn;
const generateSubscriptionId = subscriber.generateSubscriptionId;

/// Lock-Free Subscriber Registry using versioned snapshots
///
/// Architecture:
///   - Subscriptions stored in fixed-capacity array
///   - Readers take snapshots without locking
///   - Writers use atomic CAS for slot claiming
///   - Memory never freed (marked as deleted instead)
///
/// Constraints:
///   - Fixed capacity (64 slots by default)
///   - Single-threaded unsubscribe (free before deactivate to avoid races)
///   - Read-optimized for pub/sub workloads
///
pub const LockFreeSubscriberRegistry = struct {
    const Self = @This();

    subscriptions: std.atomic.Value(*SubscriptionList),
    allocator: Allocator,

    pub const SubscriptionList = struct {
        items: []SubscriptionSlot,
        count: std.atomic.Value(usize),
    };

    pub const SubscriptionSlot = struct {
        subscription: Subscription,
        active: std.atomic.Value(bool),
        ever_used: bool,

        pub fn isActive(self: *const SubscriptionSlot) bool {
            return self.active.load(.acquire);
        }

        pub fn deactivate(self: *SubscriptionSlot) void {
            self.active.store(false, .release);
        }
    };

    pub fn init(allocator: Allocator) !Self {
        const initial_capacity = 64;
        const list = try allocator.create(SubscriptionList);

        const items = try allocator.alloc(SubscriptionSlot, initial_capacity);
        @memset(items, SubscriptionSlot{
            .subscription = undefined,
            .active = std.atomic.Value(bool).init(false),
            .ever_used = false,
        });

        list.* = SubscriptionList{
            .items = items,
            .count = std.atomic.Value(usize).init(0),
            .capacity = initial_capacity,
        };

        return Self{
            .subscriptions = std.atomic.Value(*SubscriptionList).init(list),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        const list = self.subscriptions.load(.acquire);

        for (list.items) |*slot| {
            if (slot.ever_used) {
                self.allocator.free(slot.subscription.topic);
                self.allocator.free(slot.subscription.filter.conditions);
            }
        }

        self.allocator.free(list.items);
        self.allocator.destroy(list);
    }

    pub fn subscribe(
        self: *Self,
        topic: []const u8,
        filter: Filter,
        handler: HandlerFn,
    ) !SubscriptionId {
        const id = generateSubscriptionId();

        const conditions_copy = try self.allocator.dupe(Filter.WhereClause, filter.conditions);
        errdefer self.allocator.free(conditions_copy);

        const topic_copy = try self.allocator.dupe(u8, topic);
        errdefer self.allocator.free(topic_copy);

        const filter_copy = Filter{ .conditions = conditions_copy };

        const sub = Subscription{
            .id = id,
            .topic = topic_copy,
            .filter = filter_copy,
            .handler = handler,
            .created_at = std.time.timestamp(),
        };

        const list = self.subscriptions.load(.acquire);

        const max_retries = 100;
        var retries: usize = 0;
        for (list.items) |*slot| {
            if (!slot.active.load(.acquire)) {
                retries = 0;
                while (retries < max_retries) : (retries += 1) {
                    slot.subscription = sub;
                    const success = slot.active.cmpxchgWeak(
                        false,
                        true,
                        .release,
                        .acquire,
                    ) == null;

                    if (success) {
                        slot.ever_used = true;
                        _ = list.count.fetchAdd(1, .monotonic);
                        std.log.info("Subscribed: id={d} topic={s}", .{ id, topic });
                        return id;
                    }
                }
            }
        }

        std.log.err("Subscription registry full (capacity={d})", .{list.capacity});
        self.allocator.free(sub.topic);
        self.allocator.free(sub.filter.conditions);
        return error.RegistryFull;
    }

    pub fn unsubscribe(self: *Self, id: SubscriptionId) void {
        const list = self.subscriptions.load(.acquire);

        for (list.items) |*slot| {
            if (slot.isActive() and slot.subscription.id == id) {
                slot.deactivate();
                _ = list.count.fetchSub(1, .monotonic);

                std.log.info("Unsubscribed: id={d}", .{id});
                return;
            }
        }
    }

    pub fn getMatching(
        self: *Self,
        event: *const Event,
        allocator: Allocator,
    ) ![]Subscription {
        const list = self.subscriptions.load(.acquire);

        var matching_buffer: [64]Subscription = undefined;
        var matching_count: usize = 0;

        for (list.items) |*slot| {
            if (!slot.isActive()) continue;

            const sub = &slot.subscription;

            if (!sub.matchesTopic(event.topic)) {
                std.log.debug("Subscriber {d}: topic mismatch (want={s}, got={s})", .{ sub.id, sub.topic, event.topic });
                continue;
            }

            if (!sub.filter.matches(event)) {
                std.log.debug("Subscriber {d}: filter no match (conditions={d})", .{ sub.id, sub.filter.conditions.len });
                continue;
            }

            std.log.debug("Subscriber {d}: MATCHED! (topic={s}, filter_conditions={d})", .{ sub.id, sub.topic, sub.filter.conditions.len });

            if (matching_count >= matching_buffer.len) {
                std.log.warn("Too many matching subscribers (max 64)", .{});
                break;
            }

            matching_buffer[matching_count] = sub.*;
            matching_count += 1;
        }

        const result = try allocator.alloc(Subscription, matching_count);
        @memcpy(result, matching_buffer[0..matching_count]);
        return result;
    }

    pub fn getTopicSubscriptionCount(self: *Self, topic: []const u8) usize {
        const list = self.subscriptions.load(.acquire);

        var count: usize = 0;
        for (list.items) |*slot| {
            if (slot.isActive() and std.mem.eql(u8, slot.subscription.topic, topic)) {
                count += 1;
            }
        }
        return count;
    }

    pub fn getTotalSubscriptionCount(self: *Self) usize {
        const list = self.subscriptions.load(.acquire);
        return list.count.load(.acquire);
    }
};

// Test handlers
fn testHandler1(event: *const Event, allocator: Allocator) void {
    _ = event;
    _ = allocator;
}

fn testHandler2(event: *const Event, allocator: Allocator) void {
    _ = event;
    _ = allocator;
}

test "lock-free subscribe and unsubscribe" {
    const allocator = std.testing.allocator;

    var registry = try LockFreeSubscriberRegistry.init(allocator);
    defer registry.deinit();

    const filter = Filter{ .conditions = &.{} };

    const id1 = try registry.subscribe("Trade.created", filter, testHandler1);
    const id2 = try registry.subscribe("Trade.created", filter, testHandler2);

    try std.testing.expectEqual(@as(usize, 2), registry.getTopicSubscriptionCount("Trade.created"));

    registry.unsubscribe(id1);
    try std.testing.expectEqual(@as(usize, 1), registry.getTopicSubscriptionCount("Trade.created"));

    registry.unsubscribe(id2);
    try std.testing.expectEqual(@as(usize, 0), registry.getTopicSubscriptionCount("Trade.created"));
}

test "lock-free get matching subscribers" {
    const allocator = std.testing.allocator;

    var registry = try LockFreeSubscriberRegistry.init(allocator);
    defer registry.deinit();

    // Subscribe to exact topic
    const filter1 = Filter{ .conditions = &.{} };
    _ = try registry.subscribe("Trade.created", filter1, testHandler1);

    // Subscribe to wildcard topic
    const filter2 = Filter{ .conditions = &.{} };
    _ = try registry.subscribe("Trade.*", filter2, testHandler2);

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

    const matching = try registry.getMatching(&event, allocator);
    defer allocator.free(matching);

    // Both subscribers should match
    try std.testing.expectEqual(@as(usize, 2), matching.len);
}

test "lock-free filter matching in registry" {
    const allocator = std.testing.allocator;

    var registry = try LockFreeSubscriberRegistry.init(allocator);
    defer registry.deinit();

    // Subscribe with filter for high-value trades
    const filter = Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gt, .value = "1000" },
        },
    };
    _ = try registry.subscribe("Trade.created", filter, testHandler1);

    // Event with low price - should not match
    var low_price_event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "",
    };
    low_price_event.setField("price", .{ .int = 500 });

    const low_matching = try registry.getMatching(&low_price_event, allocator);
    defer allocator.free(low_matching);
    try std.testing.expectEqual(@as(usize, 0), low_matching.len);

    // Event with high price - should match
    var high_price_event = Event{
        .id = 2,
        .timestamp = 200,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 2,
        .data = "",
    };
    high_price_event.setField("price", .{ .int = 15000 });

    const high_matching = try registry.getMatching(&high_price_event, allocator);
    defer allocator.free(high_matching);
    try std.testing.expectEqual(@as(usize, 1), high_matching.len);
}
