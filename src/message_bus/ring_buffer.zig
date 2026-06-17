const std = @import("std");
const Allocator = std.mem.Allocator;
const Event = @import("../event.zig").Event;

pub const EventRingBuffer = struct {
    const Self = @This();

    const Slot = struct {
        sequence: std.atomic.Value(usize),
        event: Event,
    };

    capacity: usize,
    slots: []Slot,
    head: std.atomic.Value(usize), // Producer position
    tail: std.atomic.Value(usize), // Consumer position
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) !Self {
        if (capacity < 2) return error.InvalidCapacity;

        // Preserve the previous public behavior: a requested capacity of N can
        // hold N - 1 events.
        const usable_capacity = capacity - 1;
        const slots = try allocator.alloc(Slot, usable_capacity);
        for (slots, 0..) |*slot, i| {
            slot.* = Slot{
                .sequence = std.atomic.Value(usize).init(i),
                .event = undefined,
            };
        }

        return Self{
            .capacity = usable_capacity,
            .slots = slots,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.slots);
    }

    /// Non-blocking push (returns false if full)
    /// Thread-safe for multiple producers via CAS loop.
    ///
    /// A producer first claims a position by advancing head, writes the event,
    /// then publishes the slot with a release store to its sequence. Consumers
    /// only read slots whose sequence shows that publication completed.
    pub fn push(self: *Self, event: Event) bool {
        var head = self.head.load(.monotonic);
        while (true) {
            const slot = &self.slots[head % self.capacity];
            const sequence = slot.sequence.load(.acquire);

            if (sequence == head) {
                if (self.head.cmpxchgWeak(head, head + 1, .monotonic, .monotonic)) |updated_head| {
                    head = updated_head;
                    continue;
                }

                slot.event = event;
                slot.sequence.store(head + 1, .release);
                return true;
            }

            if (sequence < head) {
                return false; // Buffer full
            }

            head = self.head.load(.monotonic);
        }
    }

    /// Pop from consumer side (returns null if empty)
    /// Thread-safe for multiple consumers via CAS loop.
    pub fn pop(self: *Self) ?Event {
        var tail = self.tail.load(.monotonic);
        while (true) {
            const slot = &self.slots[tail % self.capacity];
            const expected_sequence = tail + 1;
            const sequence = slot.sequence.load(.acquire);

            if (sequence == expected_sequence) {
                if (self.tail.cmpxchgWeak(tail, tail + 1, .monotonic, .monotonic)) |updated_tail| {
                    tail = updated_tail;
                    continue;
                }

                const event = slot.event;
                slot.sequence.store(tail + self.capacity, .release);
                return event;
            }

            if (sequence < expected_sequence) {
                return null; // Buffer empty
            }

            tail = self.tail.load(.monotonic);
        }
    }

    pub fn size(self: *const Self) usize {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.monotonic);
        return head - tail;
    }

    pub fn isEmpty(self: *const Self) bool {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.monotonic);
        return head == tail;
    }

    pub fn isFull(self: *const Self) bool {
        return self.size() >= self.capacity;
    }
};

const RingBufferProducerContext = struct {
    buffer: *EventRingBuffer,
    start_id: usize,
    event_count: usize,
};

fn ringBufferProducer(context: RingBufferProducerContext) void {
    var i: usize = 0;
    while (i < context.event_count) : (i += 1) {
        const event_id = context.start_id + i;
        const event = Event{
            .id = @as(u128, event_id),
            .timestamp = @intCast(event_id),
            .event_type = .custom,
            .topic = "Test.concurrent",
            .model_type = "Test",
            .model_id = @intCast(event_id),
            .data = "{}",
        };

        while (!context.buffer.push(event)) {
            std.Thread.sleep(1);
        }
    }
}

const RingBufferConsumerContext = struct {
    buffer: *EventRingBuffer,
    total: usize,
    consumed: *std.atomic.Value(usize),
    seen: []std.atomic.Value(bool),
    duplicates: *std.atomic.Value(usize),
    invalid: *std.atomic.Value(bool),
};

fn ringBufferConsumer(context: RingBufferConsumerContext) void {
    while (context.consumed.load(.acquire) < context.total) {
        const event = context.buffer.pop() orelse {
            std.Thread.sleep(1);
            continue;
        };

        if (event.id >= context.total) {
            context.invalid.store(true, .release);
        } else {
            const index: usize = @intCast(event.id);
            if (context.seen[index].swap(true, .acq_rel)) {
                _ = context.duplicates.fetchAdd(1, .monotonic);
            }
        }

        _ = context.consumed.fetchAdd(1, .acq_rel);
    }
}

test "ring buffer push and pop" {
    const allocator = std.testing.allocator;

    var buffer = try EventRingBuffer.init(allocator, 4);
    defer buffer.deinit();

    const event1 = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{}",
    };

    const event2 = Event{
        .id = 2,
        .timestamp = 200,
        .event_type = .model_updated,
        .topic = "Test.updated",
        .model_type = "Test",
        .model_id = 2,
        .data = "{}",
    };

    // Push events
    try std.testing.expect(buffer.push(event1));
    try std.testing.expect(buffer.push(event2));
    try std.testing.expectEqual(@as(usize, 2), buffer.size());

    // Pop events
    const popped1 = buffer.pop().?;
    try std.testing.expectEqual(@as(u128, 1), popped1.id);

    const popped2 = buffer.pop().?;
    try std.testing.expectEqual(@as(u128, 2), popped2.id);

    // Buffer should be empty
    try std.testing.expect(buffer.pop() == null);
}

test "ring buffer full" {
    const allocator = std.testing.allocator;

    var buffer = try EventRingBuffer.init(allocator, 4);
    defer buffer.deinit();

    const event = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Test.created",
        .model_type = "Test",
        .model_id = 1,
        .data = "{}",
    };

    // Fill buffer (capacity - 1 because of ring buffer design)
    try std.testing.expect(buffer.push(event));
    try std.testing.expect(buffer.push(event));
    try std.testing.expect(buffer.push(event));

    // Next push should fail (buffer full)
    try std.testing.expect(!buffer.push(event));
}

test "ring buffer supports concurrent producers and consumers" {
    const allocator = std.testing.allocator;
    const producer_count = 4;
    const consumer_count = 4;
    const events_per_producer = 250;
    const total_events = producer_count * events_per_producer;

    var buffer = try EventRingBuffer.init(allocator, 32);
    defer buffer.deinit();

    const seen = try allocator.alloc(std.atomic.Value(bool), total_events);
    defer allocator.free(seen);
    for (seen) |*slot| {
        slot.* = std.atomic.Value(bool).init(false);
    }

    var consumed = std.atomic.Value(usize).init(0);
    var duplicates = std.atomic.Value(usize).init(0);
    var invalid = std.atomic.Value(bool).init(false);

    var consumer_threads: [consumer_count]std.Thread = undefined;
    for (&consumer_threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, ringBufferConsumer, .{RingBufferConsumerContext{
            .buffer = &buffer,
            .total = total_events,
            .consumed = &consumed,
            .seen = seen,
            .duplicates = &duplicates,
            .invalid = &invalid,
        }});
    }

    var producer_threads: [producer_count]std.Thread = undefined;
    for (&producer_threads, 0..) |*thread, producer_index| {
        thread.* = try std.Thread.spawn(.{}, ringBufferProducer, .{RingBufferProducerContext{
            .buffer = &buffer,
            .start_id = producer_index * events_per_producer,
            .event_count = events_per_producer,
        }});
    }

    for (producer_threads) |thread| {
        thread.join();
    }
    for (consumer_threads) |thread| {
        thread.join();
    }

    try std.testing.expect(buffer.isEmpty());
    try std.testing.expect(!invalid.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), duplicates.load(.acquire));
    try std.testing.expectEqual(@as(usize, total_events), consumed.load(.acquire));

    for (seen) |*slot| {
        try std.testing.expect(slot.load(.acquire));
    }
}
