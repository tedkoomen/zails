const std = @import("std");
const Allocator = std.mem.Allocator;
const Event = @import("../event.zig").Event;

pub const EventRingBuffer = struct {
    const Self = @This();

    capacity: usize,
    items: []Event,
    head: std.atomic.Value(usize), // Producer position
    tail: std.atomic.Value(usize), // Consumer position
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) !Self {
        const items = try allocator.alloc(Event, capacity);
        return Self{
            .capacity = capacity,
            .items = items,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.items);
    }

    /// Non-blocking push (returns false if full)
    /// Thread-safe for multiple producers via CAS loop
    pub fn push(self: *Self, event: Event) bool {
        while (true) {
            const head = self.head.load(.acquire);
            const next_head = (head + 1) % self.capacity;
            const tail = self.tail.load(.acquire);

            if (next_head == tail) {
                return false; // Buffer full
            }

            // CAS to claim this slot
            if (self.head.cmpxchgWeak(head, next_head, .acq_rel, .acquire)) |_| {
                // Another producer claimed this slot, retry
                continue;
            }

            // We own the slot at `head` — write the event
            self.items[head] = event;
            return true;
        }
    }

    /// Pop from consumer side (returns null if empty)
    /// Thread-safe for multiple consumers via CAS loop
    pub fn pop(self: *Self) ?Event {
        while (true) {
            const tail = self.tail.load(.acquire);
            const head = self.head.load(.acquire);

            if (tail == head) {
                return null; // Buffer empty
            }

            const event = self.items[tail];
            const next_tail = (tail + 1) % self.capacity;

            // CAS to claim this slot for consumption
            if (self.tail.cmpxchgWeak(tail, next_tail, .acq_rel, .acquire)) |_| {
                // Another consumer claimed this slot, retry
                continue;
            }

            return event;
        }
    }

    pub fn size(self: *const Self) usize {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        if (head >= tail) {
            return head - tail;
        } else {
            return self.capacity - (tail - head);
        }
    }

    pub fn isEmpty(self: *const Self) bool {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        return head == tail;
    }

    pub fn isFull(self: *const Self) bool {
        const head = self.head.load(.acquire);
        const next_head = (head + 1) % self.capacity;
        const tail = self.tail.load(.acquire);
        return next_head == tail;
    }
};

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
