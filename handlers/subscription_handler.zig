/// External event subscription handler.
///
/// Message type 252 accepts JSON commands over the existing TCP frame:
///   {"op":"subscribe","topic":"Trade.*"}
///   {"op":"poll","subscription_id":1,"timeout_ms":1000}
///   {"op":"unsubscribe","subscription_id":1}
///   {"op":"publish","topic":"Trade.created","model_type":"Trade","model_id":1,"data":"..."}
const std = @import("std");
const Allocator = std.mem.Allocator;
const globals = if (@hasDecl(@import("root"), "globals")) @import("root").globals else struct {};
const result = @import("result");

const fallback_external_api = struct {
    const EventType = enum(u8) {
        model_created = 0,
        model_updated = 1,
        model_deleted = 2,
        custom = 255,
    };
    pub const ExternalEventType = EventType;

    pub const ExternalEvent = struct {
        id: u128,
        timestamp: i64,
        event_type: EventType,
        topic: []const u8,
        model_type: []const u8,
        model_id: u64,
        data: []const u8,
    };
};

const external_api = if (@hasDecl(globals, "ExternalEvent")) globals else fallback_external_api;
const ExternalEvent = external_api.ExternalEvent;
const ExternalEventType = external_api.ExternalEventType;

pub const MESSAGE_TYPE: u8 = 252;

const MAX_EXTERNAL_SUBSCRIPTIONS = 64;
const MAX_TOPIC_SLOTS = 64;
const MAX_TOPIC_LEN = 128;
const MAX_MODEL_TYPE_LEN = 64;
const MAX_EVENT_DATA_LEN = 1024;
const MAX_QUEUED_EVENTS = 32;
const MAX_POLL_TIMEOUT_MS = 60_000;

const SubscribeError = error{
    InvalidTopic,
    BusUnavailable,
    SubscriptionLimitReached,
    TopicLimitReached,
    RegistryFull,
    OutOfMemory,
};

var bridge_context: ?*Context = null;

const QueuedEvent = struct {
    id: u128 = 0,
    timestamp: i64 = 0,
    event_type: ExternalEventType = .custom,
    topic: [MAX_TOPIC_LEN]u8 = undefined,
    topic_len: usize = 0,
    model_type: [MAX_MODEL_TYPE_LEN]u8 = undefined,
    model_type_len: usize = 0,
    model_id: u64 = 0,
    data: [MAX_EVENT_DATA_LEN]u8 = undefined,
    data_len: usize = 0,
    data_truncated: bool = false,

    fn initFrom(event: *const ExternalEvent) QueuedEvent {
        var queued = QueuedEvent{
            .id = event.id,
            .timestamp = event.timestamp,
            .event_type = event.event_type,
            .model_id = event.model_id,
        };

        queued.topic_len = @min(event.topic.len, MAX_TOPIC_LEN);
        @memcpy(queued.topic[0..queued.topic_len], event.topic[0..queued.topic_len]);

        queued.model_type_len = @min(event.model_type.len, MAX_MODEL_TYPE_LEN);
        @memcpy(queued.model_type[0..queued.model_type_len], event.model_type[0..queued.model_type_len]);

        queued.data_len = @min(event.data.len, MAX_EVENT_DATA_LEN);
        @memcpy(queued.data[0..queued.data_len], event.data[0..queued.data_len]);
        queued.data_truncated = event.data.len > MAX_EVENT_DATA_LEN;

        return queued;
    }

    fn topicSlice(self: *const QueuedEvent) []const u8 {
        return self.topic[0..self.topic_len];
    }

    fn modelTypeSlice(self: *const QueuedEvent) []const u8 {
        return self.model_type[0..self.model_type_len];
    }

    fn dataSlice(self: *const QueuedEvent) []const u8 {
        return self.data[0..self.data_len];
    }
};

const ExternalSubscription = struct {
    active: bool = false,
    id: u64 = 0,
    topic: [MAX_TOPIC_LEN]u8 = undefined,
    topic_len: usize = 0,
    queue: [MAX_QUEUED_EVENTS]QueuedEvent = [_]QueuedEvent{.{}} ** MAX_QUEUED_EVENTS,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    dropped: u64 = 0,
    delivered: u64 = 0,

    fn init(id: u64, topic: []const u8) ExternalSubscription {
        var sub = ExternalSubscription{
            .active = true,
            .id = id,
        };
        sub.topic_len = topic.len;
        @memcpy(sub.topic[0..topic.len], topic);
        return sub;
    }

    fn topicSlice(self: *const ExternalSubscription) []const u8 {
        return self.topic[0..self.topic_len];
    }

    fn containsQueuedId(self: *const ExternalSubscription, event_id: u128) bool {
        var idx = self.head;
        var seen: usize = 0;
        while (seen < self.count) : (seen += 1) {
            if (self.queue[idx].id == event_id) {
                return true;
            }
            idx = (idx + 1) % MAX_QUEUED_EVENTS;
        }
        return false;
    }

    fn enqueue(self: *ExternalSubscription, event: *const ExternalEvent) void {
        if (self.containsQueuedId(event.id)) {
            return;
        }

        if (self.count == MAX_QUEUED_EVENTS) {
            self.head = (self.head + 1) % MAX_QUEUED_EVENTS;
            self.count -= 1;
            self.dropped += 1;
        }

        self.queue[self.tail] = QueuedEvent.initFrom(event);
        self.tail = (self.tail + 1) % MAX_QUEUED_EVENTS;
        self.count += 1;
    }

    fn pop(self: *ExternalSubscription) ?QueuedEvent {
        if (self.count == 0) {
            return null;
        }

        const event = self.queue[self.head];
        self.head = (self.head + 1) % MAX_QUEUED_EVENTS;
        self.count -= 1;
        self.delivered += 1;
        return event;
    }
};

const TopicSlot = struct {
    active: bool = false,
    topic: [MAX_TOPIC_LEN]u8 = undefined,
    topic_len: usize = 0,
    bus_subscription_id: u64 = 0,
    ref_count: usize = 0,

    fn topicSlice(self: *const TopicSlot) []const u8 {
        return self.topic[0..self.topic_len];
    }
};

pub const Context = struct {
    allocator: Allocator,
    lock: std.Thread.Mutex,
    next_subscription_id: u64,
    subscriptions: [MAX_EXTERNAL_SUBSCRIPTIONS]ExternalSubscription,
    topic_slots: [MAX_TOPIC_SLOTS]TopicSlot,

    pub fn init() Context {
        return .{
            .allocator = undefined,
            .lock = .{},
            .next_subscription_id = 1,
            .subscriptions = [_]ExternalSubscription{.{}} ** MAX_EXTERNAL_SUBSCRIPTIONS,
            .topic_slots = [_]TopicSlot{.{}} ** MAX_TOPIC_SLOTS,
        };
    }

    pub fn postInit(self: *Context, allocator: Allocator) !void {
        self.allocator = allocator;
        bridge_context = self;
        std.log.info("✓ External subscription handler initialized (message type {d})", .{MESSAGE_TYPE});
    }

    pub fn deinit(self: *Context) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (comptime @hasDecl(globals, "unsubscribeExternalEvent")) {
            for (&self.topic_slots) |*slot| {
                if (slot.active) {
                    _ = globals.unsubscribeExternalEvent(slot.bus_subscription_id);
                }
            }
        }

        if (bridge_context == self) {
            bridge_context = null;
        }
    }

    fn addSubscription(self: *Context, topic: []const u8) SubscribeError!u64 {
        if (topic.len == 0 or topic.len > MAX_TOPIC_LEN) return error.InvalidTopic;

        self.lock.lock();
        defer self.lock.unlock();

        const topic_slot_index = try self.addTopicRefLocked(topic);

        for (&self.subscriptions) |*sub| {
            if (!sub.active) {
                const id = self.next_subscription_id;
                self.next_subscription_id += 1;
                sub.* = ExternalSubscription.init(id, topic);
                return id;
            }
        }

        self.removeTopicRefLocked(topic_slot_index);
        return error.SubscriptionLimitReached;
    }

    fn removeSubscription(self: *Context, subscription_id: u64) bool {
        self.lock.lock();
        defer self.lock.unlock();

        for (&self.subscriptions) |*sub| {
            if (sub.active and sub.id == subscription_id) {
                const topic_slot_index = self.findTopicSlotLocked(sub.topicSlice());
                sub.* = .{};
                if (topic_slot_index) |idx| {
                    self.removeTopicRefLocked(idx);
                }
                return true;
            }
        }

        return false;
    }

    fn popEvent(self: *Context, subscription_id: u64) ?QueuedEvent {
        self.lock.lock();
        defer self.lock.unlock();

        for (&self.subscriptions) |*sub| {
            if (sub.active and sub.id == subscription_id) {
                return sub.pop();
            }
        }

        return null;
    }

    fn queueDepth(self: *Context, subscription_id: u64) ?usize {
        self.lock.lock();
        defer self.lock.unlock();

        for (&self.subscriptions) |*sub| {
            if (sub.active and sub.id == subscription_id) {
                return sub.count;
            }
        }

        return null;
    }

    fn enqueueMatching(self: *Context, event: *const ExternalEvent) void {
        self.lock.lock();
        defer self.lock.unlock();

        for (&self.subscriptions) |*sub| {
            if (sub.active and topicMatches(sub.topicSlice(), event.topic)) {
                sub.enqueue(event);
            }
        }
    }

    fn addTopicRefLocked(self: *Context, topic: []const u8) SubscribeError!usize {
        if (self.findTopicSlotLocked(topic)) |index| {
            self.topic_slots[index].ref_count += 1;
            return index;
        }

        if (comptime !@hasDecl(globals, "subscribeExternalEvent")) {
            return error.BusUnavailable;
        }
        const bus_subscription_id = try globals.subscribeExternalEvent(topic, onExternalEvent);

        for (&self.topic_slots, 0..) |*slot, index| {
            if (!slot.active) {
                slot.* = .{
                    .active = true,
                    .topic_len = topic.len,
                    .bus_subscription_id = bus_subscription_id,
                    .ref_count = 1,
                };
                @memcpy(slot.topic[0..topic.len], topic);
                return index;
            }
        }

        _ = globals.unsubscribeExternalEvent(bus_subscription_id);
        return error.TopicLimitReached;
    }

    fn removeTopicRefLocked(self: *Context, index: usize) void {
        var slot = &self.topic_slots[index];
        if (!slot.active) {
            return;
        }

        if (slot.ref_count > 1) {
            slot.ref_count -= 1;
            return;
        }

        if (comptime @hasDecl(globals, "unsubscribeExternalEvent")) {
            _ = globals.unsubscribeExternalEvent(slot.bus_subscription_id);
        }

        slot.* = .{};
    }

    fn findTopicSlotLocked(self: *Context, topic: []const u8) ?usize {
        for (&self.topic_slots, 0..) |*slot, index| {
            if (slot.active and std.mem.eql(u8, slot.topicSlice(), topic)) {
                return index;
            }
        }
        return null;
    }
};

fn onExternalEvent(event: *const ExternalEvent) void {
    if (bridge_context) |context| {
        context.enqueueMatching(event);
    }
}

fn topicMatches(subscription_topic: []const u8, event_topic: []const u8) bool {
    if (std.mem.eql(u8, subscription_topic, event_topic)) {
        return true;
    }

    if (std.mem.endsWith(u8, subscription_topic, ".*")) {
        const prefix = subscription_topic[0 .. subscription_topic.len - 2];
        return event_topic.len > prefix.len and
            std.mem.startsWith(u8, event_topic, prefix) and
            event_topic[prefix.len] == '.';
    }

    return false;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) {
        return null;
    }
    return value.string;
}

fn getOptionalString(obj: std.json.ObjectMap, key: []const u8, default: []const u8) []const u8 {
    return getString(obj, key) orelse default;
}

fn getU64(obj: std.json.ObjectMap, key: []const u8, default: ?u64) ?u64 {
    const value = obj.get(key) orelse return default;
    switch (value) {
        .integer => |int_value| {
            if (int_value < 0) return null;
            return @intCast(int_value);
        },
        .number_string => |number_string| return std.fmt.parseInt(u64, number_string, 10) catch null,
        else => return null,
    }
}

fn parseEventType(obj: std.json.ObjectMap) ExternalEventType {
    const event_type = getString(obj, "event_type") orelse return .custom;
    if (std.mem.eql(u8, event_type, "created") or std.mem.eql(u8, event_type, "model_created")) {
        return .model_created;
    }
    if (std.mem.eql(u8, event_type, "updated") or std.mem.eql(u8, event_type, "model_updated")) {
        return .model_updated;
    }
    if (std.mem.eql(u8, event_type, "deleted") or std.mem.eql(u8, event_type, "model_deleted")) {
        return .model_deleted;
    }
    return .custom;
}

fn eventTypeName(event_type: ExternalEventType) []const u8 {
    return switch (event_type) {
        .model_created => "model_created",
        .model_updated => "model_updated",
        .model_deleted => "model_deleted",
        .custom => "custom",
    };
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn writeError(response_buffer: []u8, message: []const u8) result.HandlerResponse {
    var stream = std.io.fixedBufferStream(response_buffer);
    const writer = stream.writer();
    writer.writeAll("{\"status\":\"error\",\"message\":") catch return result.HandlerResponse.err(.message_too_large);
    writeJsonString(writer, message) catch return result.HandlerResponse.err(.message_too_large);
    writer.writeByte('}') catch return result.HandlerResponse.err(.message_too_large);
    return result.HandlerResponse.ok(stream.getWritten());
}

fn writeSubscribeResponse(response_buffer: []u8, subscription_id: u64) result.HandlerResponse {
    var stream = std.io.fixedBufferStream(response_buffer);
    const writer = stream.writer();
    writer.print("{{\"status\":\"ok\",\"subscription_id\":{d}}}", .{subscription_id}) catch {
        return result.HandlerResponse.err(.message_too_large);
    };
    return result.HandlerResponse.ok(stream.getWritten());
}

fn writeUnsubscribeResponse(response_buffer: []u8, removed: bool) result.HandlerResponse {
    var stream = std.io.fixedBufferStream(response_buffer);
    const writer = stream.writer();
    writer.print("{{\"status\":\"ok\",\"removed\":{s}}}", .{if (removed) "true" else "false"}) catch {
        return result.HandlerResponse.err(.message_too_large);
    };
    return result.HandlerResponse.ok(stream.getWritten());
}

fn writePublishResponse(response_buffer: []u8) result.HandlerResponse {
    const body = "{\"status\":\"ok\",\"published\":true}";
    if (body.len > response_buffer.len) return result.HandlerResponse.err(.message_too_large);
    @memcpy(response_buffer[0..body.len], body);
    return result.HandlerResponse.ok(response_buffer[0..body.len]);
}

fn writeTimeoutResponse(response_buffer: []u8, subscription_id: u64) result.HandlerResponse {
    var stream = std.io.fixedBufferStream(response_buffer);
    const writer = stream.writer();
    writer.print("{{\"status\":\"timeout\",\"subscription_id\":{d}}}", .{subscription_id}) catch {
        return result.HandlerResponse.err(.message_too_large);
    };
    return result.HandlerResponse.ok(stream.getWritten());
}

fn writeEventResponse(response_buffer: []u8, subscription_id: u64, event: QueuedEvent, queue_depth: usize) result.HandlerResponse {
    var stream = std.io.fixedBufferStream(response_buffer);
    const writer = stream.writer();

    writer.print("{{\"status\":\"ok\",\"subscription_id\":{d},\"queue_depth\":{d},\"event\":{{\"id\":\"{d}\",\"timestamp\":{d},\"event_type\":", .{
        subscription_id,
        queue_depth,
        event.id,
        event.timestamp,
    }) catch return result.HandlerResponse.err(.message_too_large);
    writeJsonString(writer, eventTypeName(event.event_type)) catch return result.HandlerResponse.err(.message_too_large);
    writer.writeAll(",\"topic\":") catch return result.HandlerResponse.err(.message_too_large);
    writeJsonString(writer, event.topicSlice()) catch return result.HandlerResponse.err(.message_too_large);
    writer.writeAll(",\"model_type\":") catch return result.HandlerResponse.err(.message_too_large);
    writeJsonString(writer, event.modelTypeSlice()) catch return result.HandlerResponse.err(.message_too_large);
    writer.print(",\"model_id\":{d},\"data\":", .{event.model_id}) catch return result.HandlerResponse.err(.message_too_large);
    writeJsonString(writer, event.dataSlice()) catch return result.HandlerResponse.err(.message_too_large);
    writer.print(",\"data_truncated\":{s}}}}}", .{if (event.data_truncated) "true" else "false"}) catch {
        return result.HandlerResponse.err(.message_too_large);
    };

    return result.HandlerResponse.ok(stream.getWritten());
}

fn handleSubscribe(context: *Context, obj: std.json.ObjectMap, response_buffer: []u8) result.HandlerResponse {
    const topic = getString(obj, "topic") orelse {
        return writeError(response_buffer, "missing topic");
    };

    const subscription_id = context.addSubscription(topic) catch |err| {
        return switch (err) {
            error.BusUnavailable => writeError(response_buffer, "message bus unavailable"),
            error.InvalidTopic => writeError(response_buffer, "invalid topic"),
            error.SubscriptionLimitReached => writeError(response_buffer, "subscription limit reached"),
            error.RegistryFull => writeError(response_buffer, "subscription limit reached"),
            error.TopicLimitReached => writeError(response_buffer, "topic limit reached"),
            else => result.HandlerResponse.err(.handler_failed),
        };
    };

    return writeSubscribeResponse(response_buffer, subscription_id);
}

fn handleUnsubscribe(context: *Context, obj: std.json.ObjectMap, response_buffer: []u8) result.HandlerResponse {
    const subscription_id = getU64(obj, "subscription_id", null) orelse {
        return writeError(response_buffer, "missing subscription_id");
    };

    const removed = context.removeSubscription(subscription_id);
    return writeUnsubscribeResponse(response_buffer, removed);
}

fn handlePoll(context: *Context, obj: std.json.ObjectMap, response_buffer: []u8) result.HandlerResponse {
    const subscription_id = getU64(obj, "subscription_id", null) orelse {
        return writeError(response_buffer, "missing subscription_id");
    };
    const timeout_ms_raw = getU64(obj, "timeout_ms", 0) orelse 0;
    const timeout_ms = @min(timeout_ms_raw, MAX_POLL_TIMEOUT_MS);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    while (true) {
        if (context.popEvent(subscription_id)) |event| {
            const depth = context.queueDepth(subscription_id) orelse 0;
            return writeEventResponse(response_buffer, subscription_id, event, depth);
        }

        if (timeout_ms == 0 or std.time.milliTimestamp() >= deadline) {
            return writeTimeoutResponse(response_buffer, subscription_id);
        }

        std.Thread.sleep(std.time.ns_per_ms);
    }
}

fn handlePublish(context: *Context, obj: std.json.ObjectMap, response_buffer: []u8) result.HandlerResponse {
    _ = context;
    if (comptime !@hasDecl(globals, "publishExternalEvent")) {
        return writeError(response_buffer, "message bus unavailable");
    }

    const topic = getString(obj, "topic") orelse {
        return writeError(response_buffer, "missing topic");
    };
    if (topic.len == 0 or topic.len > MAX_TOPIC_LEN) {
        return writeError(response_buffer, "invalid topic");
    }

    const model_type = getOptionalString(obj, "model_type", "");
    if (model_type.len > MAX_MODEL_TYPE_LEN) {
        return writeError(response_buffer, "model_type too large");
    }

    const model_id = getU64(obj, "model_id", 0) orelse {
        return writeError(response_buffer, "invalid model_id");
    };
    const data = getOptionalString(obj, "data", "");

    globals.publishExternalEvent(
        parseEventType(obj),
        topic,
        model_type,
        model_id,
        data,
    ) catch {
        return result.HandlerResponse.err(.handler_failed);
    };

    return writePublishResponse(response_buffer);
}

/// Process external subscription requests.
pub fn handle(
    context: *Context,
    request_data: []const u8,
    response_buffer: []u8,
    allocator: Allocator,
) result.HandlerResponse {
    if (request_data.len == 0) {
        return result.HandlerResponse.err(.malformed_message);
    }

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        request_data,
        .{},
    ) catch {
        return result.HandlerResponse.err(.malformed_message);
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return result.HandlerResponse.err(.malformed_message);
    }
    const obj = parsed.value.object;

    const op = getString(obj, "op") orelse {
        return writeError(response_buffer, "missing op");
    };

    if (std.mem.eql(u8, op, "subscribe")) {
        return handleSubscribe(context, obj, response_buffer);
    }
    if (std.mem.eql(u8, op, "poll")) {
        return handlePoll(context, obj, response_buffer);
    }
    if (std.mem.eql(u8, op, "unsubscribe")) {
        return handleUnsubscribe(context, obj, response_buffer);
    }
    if (std.mem.eql(u8, op, "publish")) {
        return handlePublish(context, obj, response_buffer);
    }

    return writeError(response_buffer, "unknown op");
}

test "topic matching exact and wildcard" {
    try std.testing.expect(topicMatches("Trade.created", "Trade.created"));
    try std.testing.expect(!topicMatches("Trade.created", "Trade.updated"));
    try std.testing.expect(topicMatches("Trade.*", "Trade.updated"));
    try std.testing.expect(!topicMatches("Trade.*", "Trade"));
    try std.testing.expect(!topicMatches("Trade.*", "Portfolio.updated"));
}

test "queued event drops oldest when full" {
    var sub = ExternalSubscription.init(1, "Trade.created");
    for (0..MAX_QUEUED_EVENTS + 1) |i| {
        const event = ExternalEvent{
            .id = i + 1,
            .timestamp = 0,
            .event_type = .custom,
            .topic = "Trade.created",
            .model_type = "Trade",
            .model_id = @intCast(i),
            .data = "{}",
        };
        sub.enqueue(&event);
    }

    try std.testing.expectEqual(@as(usize, MAX_QUEUED_EVENTS), sub.count);
    try std.testing.expectEqual(@as(u64, 1), sub.dropped);
    const event = sub.pop().?;
    try std.testing.expectEqual(@as(u128, 2), event.id);
}
