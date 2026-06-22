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
///   - inactive (0): slot has never been used, can be claimed by a writer
///   - writing  (1): slot is being written to, readers must skip
///   - active   (2): slot has valid data, readers can access
///   - deleted  (3): slot has old subscription data retained for deinit
///
/// This eliminates the race where two threads both write subscription data
/// to the same slot before the CAS — now the CAS happens FIRST.
///
pub const LockFreeSubscriberRegistry = struct {
    const Self = @This();

    const SLOT_INACTIVE: u8 = 0;
    const SLOT_WRITING: u8 = 1;
    const SLOT_ACTIVE: u8 = 2;
    const SLOT_DELETED: u8 = 3;

    // Subscriptions array (grows via RCU, never shrinks)
    subscriptions: std.atomic.Value(*SubscriptionList),
    // Serialize the rare RCU growth path. Slot claims remain lock-free, but
    // replacing the list must be single-writer or concurrent grows lose updates.
    growth_lock: std.Thread.Mutex = .{},
    // Track old lists from RCU growth for deferred cleanup in deinit().
    // Concurrent readers may still reference old lists, so we can't free them
    // immediately. We stash them here and free the containers (but not subscription
    // data, which was memcpy'd to the new list) in deinit().
    old_lists: std.ArrayList(*SubscriptionList) = .{},
    allocator: Allocator,

    pub const SubscriptionList = struct {
        items: []SubscriptionSlot,
        count: std.atomic.Value(usize), // Active subscription count
        capacity: usize,
    };

    pub const SubscriptionRecord = struct {
        subscription: Subscription,
        active: std.atomic.Value(bool),
    };

    pub const SubscriptionSlot = struct {
        record: ?*SubscriptionRecord,
        state: std.atomic.Value(u8), // SLOT_INACTIVE / SLOT_WRITING / SLOT_ACTIVE / SLOT_DELETED
        ever_used: bool, // true if subscription data has been written

        pub fn isActive(self: *const SubscriptionSlot) bool {
            if (self.state.load(.acquire) != SLOT_ACTIVE) return false;
            const record = self.record orelse return false;
            return record.active.load(.acquire);
        }

        pub fn deactivate(self: *SubscriptionSlot) void {
            if (self.record) |record| {
                record.active.store(false, .release);
            }
            self.state.store(SLOT_DELETED, .release);
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

    pub const MatchingIterator = struct {
        list: *SubscriptionList,
        event: *const Event,
        index: usize = 0,

        pub fn next(self: *MatchingIterator) ?Subscription {
            while (self.index < self.list.items.len) {
                const slot = &self.list.items[self.index];
                self.index += 1;

                if (!slot.isActive()) continue;

                const record = slot.record orelse continue;
                const sub = &record.subscription;
                if (!sub.matchesTopic(self.event.topic)) continue;
                if (!sub.filter.matches(self.event)) continue;

                return sub.*;
            }

            return null;
        }
    };

    pub fn init(allocator: Allocator) !Self {
        const initial_capacity = 64;
        const list = try allocator.create(SubscriptionList);
        errdefer allocator.destroy(list);

        const items = try allocator.alloc(SubscriptionSlot, initial_capacity);
        @memset(items, SubscriptionSlot{
            .record = null,
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
                if (slot.record) |record| {
                    self.destroyRecord(record);
                }
            }
        }

        self.allocator.free(list.items);
        self.allocator.destroy(list);

        // Free old list containers from RCU growth. Subscription records are shared
        // with the current list and were freed above exactly once.
        for (self.old_lists.items) |old| {
            self.allocator.free(old.items);
            self.allocator.destroy(old);
        }
        self.old_lists.deinit(self.allocator);
    }

    fn destroyRecord(self: *Self, record: *SubscriptionRecord) void {
        self.allocator.free(record.subscription.topic);
        self.allocator.free(record.subscription.filter.conditions);
        self.allocator.destroy(record);
    }

    fn claimInactiveSlot(list: *SubscriptionList, record: *SubscriptionRecord) bool {
        for (list.items) |*slot| {
            // Three-state protocol: CAS inactive -> writing FIRST, then write data.
            if (slot.state.cmpxchgWeak(
                SLOT_INACTIVE,
                SLOT_WRITING,
                .acquire,
                .monotonic,
            ) != null) {
                continue;
            }

            slot.record = record;
            slot.ever_used = true;

            // Publish: make data visible to readers.
            slot.state.store(SLOT_ACTIVE, .release);
            _ = list.count.fetchAdd(1, .monotonic);
            return true;
        }

        return false;
    }

    fn activeCount(list: *SubscriptionList) usize {
        var count: usize = 0;
        for (list.items) |*slot| {
            if (slot.isActive()) count += 1;
        }
        return count;
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

        const record = try self.allocator.create(SubscriptionRecord);
        var record_published = false;
        errdefer if (!record_published) self.allocator.destroy(record);

        record.* = .{
            .subscription = .{
                .id = id,
                .topic = topic_copy,
                .filter = filter_copy,
                .handler = handler,
                .created_at = std.time.timestamp(),
                .topic_pattern = Subscription.computeTopicPattern(topic),
            },
            .active = std.atomic.Value(bool).init(true),
        };

        self.growth_lock.lock();
        defer self.growth_lock.unlock();

        // Subscribe/unsubscribe are control-plane operations. Serializing writers
        // prevents a fast-path slot claim from landing in an old list while a
        // growth snapshot is being copied.
        const list = self.subscriptions.load(.acquire);
        if (claimInactiveSlot(list, record)) {
            record_published = true;
            std.log.info("Subscribed: id={d} topic={s}", .{ id, topic });
            return id;
        }

        // All slots full — grow via RCU
        const new_capacity = list.capacity * 2;
        const new_list = try self.allocator.create(SubscriptionList);
        errdefer self.allocator.destroy(new_list);

        const new_items = try self.allocator.alloc(SubscriptionSlot, new_capacity);
        errdefer self.allocator.free(new_items);

        // Copy existing slots. Slots now point at shared SubscriptionRecord
        // objects, so an unsubscribe tombstone is visible to old and new lists.
        @memcpy(new_items[0..list.capacity], list.items);
        // Initialize new slots
        for (new_items[list.capacity..]) |*slot| {
            slot.* = SubscriptionSlot{
                .record = null,
                .state = std.atomic.Value(u8).init(SLOT_INACTIVE),
                .ever_used = false,
            };
        }

        new_list.* = SubscriptionList{
            .items = new_items,
            .count = std.atomic.Value(usize).init(activeCount(list)),
            .capacity = new_capacity,
        };

        // Stash old list before publishing the replacement. Concurrent readers may
        // still reference it, so only deinit frees old containers.
        try self.old_lists.append(self.allocator, list);

        // Place subscription in first new slot
        new_items[list.capacity].record = record;
        new_items[list.capacity].ever_used = true;
        new_items[list.capacity].state = std.atomic.Value(u8).init(SLOT_ACTIVE);
        new_list.count.store(activeCount(list) + 1, .monotonic);

        // Publish the new list. The growth lock makes this single-writer.
        self.subscriptions.store(new_list, .release);
        record_published = true;

        std.log.info("Subscribed: id={d} topic={s} (grew registry to {d} slots)", .{ id, topic, new_capacity });
        return id;
    }

    /// Remove subscription.
    /// Memory is NOT freed here to avoid use-after-free with concurrent readers.
    /// Memory is reclaimed in deinit().
    pub fn unsubscribe(self: *Self, id: SubscriptionId) void {
        const list = self.subscriptions.load(.acquire);

        for (list.items) |*slot| {
            if (!slot.isActive()) continue;
            const record = slot.record orelse continue;
            if (record.subscription.id == id) {
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

            const record = slot.record orelse continue;
            const sub = &record.subscription;

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

    /// Iterate matching subscribers from a single RCU snapshot without heap
    /// allocation and without the legacy MatchResult fanout cap.
    pub fn matchingIterator(
        self: *Self,
        event: *const Event,
    ) MatchingIterator {
        return .{
            .list = self.subscriptions.load(.acquire),
            .event = event,
        };
    }

    /// Legacy API: allocates result on heap. Prefer getMatchingResult() for hot path.
    pub fn getMatching(
        self: *Self,
        event: *const Event,
        allocator: Allocator,
    ) ![]Subscription {
        const list = self.subscriptions.load(.acquire);
        var matches: std.ArrayList(Subscription) = .{};
        errdefer matches.deinit(allocator);

        var it = MatchingIterator{ .list = list, .event = event };
        while (it.next()) |sub| {
            try matches.append(allocator, sub);
        }
        return try matches.toOwnedSlice(allocator);
    }

    pub fn getTopicSubscriptionCount(self: *Self, topic: []const u8) usize {
        const list = self.subscriptions.load(.acquire);

        var count: usize = 0;
        for (list.items) |*slot| {
            if (!slot.isActive()) continue;
            const record = slot.record orelse continue;
            if (std.mem.eql(u8, record.subscription.topic, topic)) {
                count += 1;
            }
        }
        return count;
    }

    pub fn getTotalSubscriptionCount(self: *Self) usize {
        const list = self.subscriptions.load(.acquire);
        return activeCount(list);
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

test "unsubscribe tombstone is shared across grown snapshots" {
    const allocator = std.testing.allocator;

    var registry = try LockFreeSubscriberRegistry.init(allocator);
    defer registry.deinit();

    const filter = Filter{ .conditions = &.{} };

    var ids: [65]u64 = undefined;
    for (0..64) |i| {
        var topic_buf: [32]u8 = undefined;
        const topic = try std.fmt.bufPrint(&topic_buf, "topic.{d}", .{i});
        ids[i] = try registry.subscribe(topic, filter, testHandler1);
    }

    const old_list = registry.subscriptions.load(.acquire);

    ids[64] = try registry.subscribe("topic.grown", filter, testHandler1);
    const new_list = registry.subscriptions.load(.acquire);
    try std.testing.expect(old_list != new_list);

    registry.unsubscribe(ids[0]);

    var old_active = false;
    for (old_list.items) |*slot| {
        const record = slot.record orelse continue;
        if (record.subscription.id == ids[0]) {
            old_active = slot.isActive();
            break;
        }
    }

    var new_active = false;
    for (new_list.items) |*slot| {
        const record = slot.record orelse continue;
        if (record.subscription.id == ids[0]) {
            new_active = slot.isActive();
            break;
        }
    }

    try std.testing.expect(!old_active);
    try std.testing.expect(!new_active);
}
