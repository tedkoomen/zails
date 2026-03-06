const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Event = @import("../event.zig").Event;
const Filter = @import("filter.zig").Filter;
const subscriber = @import("subscriber.zig");
const Subscription = subscriber.Subscription;
const SubscriptionId = subscriber.SubscriptionId;
const HandlerFn = subscriber.HandlerFn;
const generateSubscriptionId = subscriber.generateSubscriptionId;

pub const SubscriberRegistry = struct {
    const Self = @This();

    subscriptions: std.StringHashMap(ArrayList(Subscription)),
    lock: std.Thread.RwLock, 
    allocator: Allocator,

    pub fn init(allocator: Allocator) Self {
        return Self{
            .subscriptions = std.StringHashMap(ArrayList(Subscription)).init(allocator),
            .lock = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |sub| {
                self.allocator.free(sub.topic);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.subscriptions.deinit();
    }

    pub fn subscribe(
        self: *Self,
        topic: []const u8,
        filter: Filter,
        handler: HandlerFn,
    ) !SubscriptionId {
        self.lock.lock();
        defer self.lock.unlock();

        const id = generateSubscriptionId();
        const sub = Subscription{
            .id = id,
            .topic = try self.allocator.dupe(u8, topic),
            .filter = filter,
            .handler = handler,
            .created_at = std.time.timestamp(),
        };

        var result = try self.subscriptions.getOrPut(topic);
        if (!result.found_existing) {
            result.value_ptr.* = ArrayList(Subscription){};
        }

        try result.value_ptr.append(self.allocator, sub);

        std.log.info("Subscribed: id={d} topic={s}", .{ id, topic });
        return id;
    }

    pub fn unsubscribe(self: *Self, id: SubscriptionId) void {
        self.lock.lock();
        defer self.lock.unlock();

        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items, 0..) |sub, i| {
                if (sub.id == id) {
                    _ = entry.value_ptr.swapRemove(i);
                    self.allocator.free(sub.topic);
                    std.log.info("Unsubscribed: id={d}", .{id});
                    return;
                }
            }
        }
    }

    pub fn getMatching(
        self: *Self,
        event: *const Event,
        allocator: Allocator,
    ) ![]Subscription {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var matching = ArrayList(Subscription){};

        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |sub| {
                if (!sub.matchesTopic(event.topic)) continue;

                if (!sub.filter.matches(event)) continue;

                try matching.append(allocator, sub);
            }
        }

        return matching.toOwnedSlice(allocator);
    }

    pub fn getTopicSubscriptionCount(self: *Self, topic: []const u8) usize {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        if (self.subscriptions.get(topic)) |subs| {
            return subs.items.len;
        }
        return 0;
    }

    pub fn getTotalSubscriptionCount(self: *Self) usize {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var total: usize = 0;
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.items.len;
        }
        return total;
    }
};

fn testHandler1(event: *const Event, allocator: Allocator) void {
    _ = event;
    _ = allocator;
}

fn testHandler2(event: *const Event, allocator: Allocator) void {
    _ = event;
    _ = allocator;
}

test "subscribe and unsubscribe" {
    const allocator = std.testing.allocator;

    var registry = SubscriberRegistry.init(allocator);
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

test "get matching subscribers" {
    const allocator = std.testing.allocator;

    var registry = SubscriberRegistry.init(allocator);
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

test "filter matching in registry" {
    const allocator = std.testing.allocator;

    var registry = SubscriberRegistry.init(allocator);
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
