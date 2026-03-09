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
///   - Subscriptions stored in fixed-capacity array (grows via RCU)
///   - Readers take snapshots without locking
///   - Writers use atomic CAS for slot claiming with three-state protocol
///   - Memory never freed until deinit (marked as deleted instead)
///
/// Slot states:
///   - inactive (0): slot is free, can be claimed by a writer
///   - writing  (1): slot is being written to, readers must skip
///   - active   (2): slot has valid data, readers can access
///
/// This eliminates the race where two threads both write subscription data
/// to the same slot before the CAS — now the CAS happens FIRST.
///
pub const LockFreeSubscriberRegistry = struct {
    const Self = @This();

    const SLOT_INACTIVE: u8 = 0;
    const SLOT_WRITING: u8 = 1;
    const SLOT_ACTIVE: u8 = 2;

    // Subscriptions array (grows via RCU, never shrinks)
    subscriptions: std.atomic.Value(*SubscriptionList),
    // Track old lists from RCU growth for deferred cleanup in deinit().
    // Concurrent readers may still reference old lists, so we can't free them
    // immediately. We stash them here and free the containers (but not subscription
    // data, which was memcpy'd to the new list) in deinit().
    old_lists: [16]*SubscriptionList = undefined,
    old_lists_count: usize = 0,
    allocator: Allocator,

    pub const SubscriptionList = struct {
        items: []SubscriptionSlot,
        count: std.atomic.Value(usize), // Active subscription count
        capacity: usize,
    };

    pub const SubscriptionSlot = struct {
        subscription: Subscription,
        state: std.atomic.Value(u8), // SLOT_INACTIVE / SLOT_WRITING / SLOT_ACTIVE
        ever_used: bool, // true if subscription data has been written

        pub fn isActive(self: *const SubscriptionSlot) bool {
            return self.state.load(.acquire) == SLOT_ACTIVE;
        }

        pub fn deactivate(self: *SubscriptionSlot) void {
            self.state.store(SLOT_INACTIVE, .release);
        }
    };

    /// Return type for getMatching — avoids heap allocation on hot path.
    /// Contains a stack buffer of up to 64 matching subscriptions.
    pub const MatchResult = struct {
        buffer: [64]Subscription,
        count: usize,

        pub fn slice(self: *const MatchResult) []const Subscription {
            return self.buffer[0..self.count];
        }
    };

    pub fn init(allocator: Allocator) !Self {
        const initial_capacity = 64;
        const list = try allocator.create(SubscriptionList);

        const items = try allocator.alloc(SubscriptionSlot, initial_capacity);
        @memset(items, SubscriptionSlot{
            .subscription = undefined,
            .state = std.atomic.Value(u8).init(SLOT_INACTIVE),
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

        // Free allocated memory for all slots that have been used
        // (both active and deactivated, since unsubscribe no longer frees)
        for (list.items) |*slot| {
            if (slot.ever_used) {
                self.allocator.free(slot.subscription.topic);
                self.allocator.free(slot.subscription.filter.conditions);
            }
        }

        self.allocator.free(list.items);
        self.allocator.destroy(list);

        // Free old list containers from RCU growth. Subscription data is NOT freed
        // here — it was memcpy'd into the current list and freed above.
        for (self.old_lists[0..self.old_lists_count]) |old| {
            self.allocator.free(old.items);
            self.allocator.destroy(old);
        }
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

        // Pre-parse filter values at subscribe time to avoid runtime parsing on every match
        for (conditions_copy) |*cond| {
            if (cond.parsed == .unparsed) {
                cond.parsed = Filter.parseValue(cond.value);
            }
        }

        const topic_copy = try self.allocator.dupe(u8, topic);
        errdefer self.allocator.free(topic_copy);

        const filter_copy = Filter{ .conditions = conditions_copy };

        const sub = Subscription{
            .id = id,
            .topic = topic_copy,
            .filter = filter_copy,
            .handler = handler,
            .created_at = std.time.timestamp(),
            .topic_pattern = Subscription.computeTopicPattern(topic),
        };

        var list = self.subscriptions.load(.acquire);

        // Try to find and claim an inactive slot
        for (list.items) |*slot| {
            // Three-state protocol: CAS inactive → writing FIRST, then write data
            if (slot.state.cmpxchgWeak(
                SLOT_INACTIVE,
                SLOT_WRITING,
                .acquire,
                .monotonic,
            ) != null) {
                // Slot was not inactive (already active or being written by another thread)
                continue;
            }

            // We own this slot exclusively. Write the subscription data.
            slot.subscription = sub;
            slot.ever_used = true;

            // Publish: make data visible to readers
            slot.state.store(SLOT_ACTIVE, .release);
            _ = list.count.fetchAdd(1, .monotonic);

            std.log.info("Subscribed: id={d} topic={s}", .{ id, topic });
            return id;
        }

        // All slots full — grow via RCU
        const new_capacity = list.capacity * 2;
        const new_list = try self.allocator.create(SubscriptionList);
        errdefer self.allocator.destroy(new_list);

        const new_items = try self.allocator.alloc(SubscriptionSlot, new_capacity);
        errdefer self.allocator.free(new_items);

        // Copy existing slots
        @memcpy(new_items[0..list.capacity], list.items);
        // Initialize new slots
        for (new_items[list.capacity..]) |*slot| {
            slot.* = SubscriptionSlot{
                .subscription = undefined,
                .state = std.atomic.Value(u8).init(SLOT_INACTIVE),
                .ever_used = false,
            };
        }

        new_list.* = SubscriptionList{
            .items = new_items,
            .count = std.atomic.Value(usize).init(list.count.load(.monotonic)),
            .capacity = new_capacity,
        };

        // Place subscription in first new slot
        new_items[list.capacity].subscription = sub;
        new_items[list.capacity].ever_used = true;
        new_items[list.capacity].state = std.atomic.Value(u8).init(SLOT_ACTIVE);
        new_list.count.store(list.count.load(.monotonic) + 1, .monotonic);

        // Atomically swap in the new list
        self.subscriptions.store(new_list, .release);

        // Stash old list for deferred cleanup in deinit(). Concurrent readers may
        // still reference it, so we can't free now. The subscription data was memcpy'd
        // to the new list, so we only need to free the container + items array later.
        if (self.old_lists_count < self.old_lists.len) {
            self.old_lists[self.old_lists_count] = list;
            self.old_lists_count += 1;
        }

        std.log.info("Subscribed: id={d} topic={s} (grew registry to {d} slots)", .{ id, topic, new_capacity });
        return id;
    }

    /// Remove subscription.
    /// Memory is NOT freed here to avoid use-after-free with concurrent readers.
    /// Memory is reclaimed in deinit().
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

    /// Get matching subscribers for an event.
    /// Returns a stack-allocated MatchResult — zero heap allocation on the hot path.
    ///
    /// TODO(perf): O(n) linear scan over all slots including inactive ones.
    ///   Consider maintaining a separate active-only list or compact on unsubscribe.
    /// TODO(perf): Copies full Subscription structs (~80+ bytes each) into MatchResult buffer.
    ///   Consider storing pointers instead (safe under RCU — slots are never freed until deinit).
    /// TODO(perf): TopicRegistry.get() hashes the event topic string once per subscriber.
    ///   Hash once before the loop and pass the topic_id to matches().
    pub fn getMatchingResult(
        self: *Self,
        event: *const Event,
    ) MatchResult {
        const list = self.subscriptions.load(.acquire);

        var result = MatchResult{
            .buffer = undefined,
            .count = 0,
        };

        for (list.items) |*slot| {
            if (!slot.isActive()) continue;

            const sub = &slot.subscription;

            if (!sub.matchesTopic(event.topic)) continue;
            if (!sub.filter.matches(event)) continue;

            if (result.count >= result.buffer.len) {
                std.log.warn("Too many matching subscribers (max 64)", .{});
                break;
            }

            result.buffer[result.count] = sub.*;
            result.count += 1;
        }

        return result;
    }

    /// Legacy API: allocates result on heap. Prefer getMatchingResult() for hot path.
    pub fn getMatching(
        self: *Self,
        event: *const Event,
        allocator: Allocator,
    ) ![]Subscription {
        const match_result = self.getMatchingResult(event);
        const result = try allocator.alloc(Subscription, match_result.count);
        @memcpy(result, match_result.buffer[0..match_result.count]);
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

test "lock-free get matching via stack result (zero alloc)" {
    const allocator = std.testing.allocator;

    var registry = try LockFreeSubscriberRegistry.init(allocator);
    defer registry.deinit();

    const filter = Filter{ .conditions = &.{} };
    _ = try registry.subscribe("Trade.created", filter, testHandler1);
    _ = try registry.subscribe("Trade.*", filter, testHandler2);

    var event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "",
    };

    // No allocator needed — result is on the stack
    const result = registry.getMatchingResult(&event);
    try std.testing.expectEqual(@as(usize, 2), result.count);
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

test "subscriber registry grows beyond 64 slots" {
    const allocator = std.testing.allocator;

    var registry = try LockFreeSubscriberRegistry.init(allocator);
    defer registry.deinit();

    const filter = Filter{ .conditions = &.{} };

    // Subscribe more than 64 times
    var ids: [100]u64 = undefined;
    for (0..100) |i| {
        var topic_buf: [32]u8 = undefined;
        const topic = try std.fmt.bufPrint(&topic_buf, "topic.{d}", .{i});
        ids[i] = try registry.subscribe(topic, filter, testHandler1);
    }

    try std.testing.expectEqual(@as(usize, 100), registry.getTotalSubscriptionCount());

    for (ids) |id| registry.unsubscribe(id);
}
