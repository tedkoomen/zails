const std = @import("std");
const Allocator = std.mem.Allocator;

const SLOT_FREE: u8 = 0;
const SLOT_USED: u8 = 1;
const INVALID_SLOT = std.math.maxInt(u32);

pub const PayloadHandle = struct {
    pool: *PayloadPool,
    slot: u32,
    generation: u32,
};

pub const PayloadReservation = struct {
    handle: PayloadHandle,
    bytes: []u8,
};

pub const PayloadPool = struct {
    const Self = @This();

    const TaggedHead = struct {
        slot: u32,
        tag: u32,
    };

    const Slot = struct {
        next: std.atomic.Value(u32),
        generation: std.atomic.Value(u32),
        state: std.atomic.Value(u8),
    };

    slots: []Slot,
    storage: []u8,
    slot_size: usize,
    free_head: std.atomic.Value(u64),
    allocator: Allocator,

    fn packHead(head: TaggedHead) u64 {
        return (@as(u64, head.tag) << 32) | @as(u64, head.slot);
    }

    fn unpackHead(value: u64) TaggedHead {
        return .{
            .slot = @truncate(value),
            .tag = @truncate(value >> 32),
        };
    }

    pub fn init(allocator: Allocator, slot_count: usize, slot_size: usize) !Self {
        if (slot_count == 0 or slot_count > @as(usize, INVALID_SLOT)) return error.InvalidPayloadPoolCapacity;
        if (slot_size == 0) return error.InvalidPayloadSlotSize;

        const slots = try allocator.alloc(Slot, slot_count);
        errdefer allocator.free(slots);

        const storage = try allocator.alloc(u8, slot_count * slot_size);
        errdefer allocator.free(storage);

        for (slots, 0..) |*slot, i| {
            const next: u32 = if (i + 1 < slot_count) @intCast(i + 1) else INVALID_SLOT;
            slot.* = .{
                .next = std.atomic.Value(u32).init(next),
                .generation = std.atomic.Value(u32).init(1),
                .state = std.atomic.Value(u8).init(SLOT_FREE),
            };
        }

        return .{
            .slots = slots,
            .storage = storage,
            .slot_size = slot_size,
            .free_head = std.atomic.Value(u64).init(packHead(.{ .slot = 0, .tag = 0 })),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.storage);
        self.allocator.free(self.slots);
    }

    pub fn reserve(self: *Self, byte_len: usize) ?PayloadReservation {
        if (byte_len > self.slot_size) return null;

        var packed_head = self.free_head.load(.acquire);
        while (true) {
            const head = unpackHead(packed_head);
            if (head.slot == INVALID_SLOT) return null;

            const slot = &self.slots[head.slot];
            const next = slot.next.load(.acquire);
            const updated_head = packHead(.{ .slot = next, .tag = head.tag +% 1 });
            if (self.free_head.cmpxchgWeak(packed_head, updated_head, .acq_rel, .monotonic)) |updated| {
                packed_head = updated;
                continue;
            }

            slot.state.store(SLOT_USED, .release);
            const start = @as(usize, head.slot) * self.slot_size;
            return .{
                .handle = .{
                    .pool = self,
                    .slot = head.slot,
                    .generation = slot.generation.load(.acquire),
                },
                .bytes = self.storage[start .. start + byte_len],
            };
        }
    }

    pub fn release(self: *Self, handle: PayloadHandle) bool {
        if (handle.slot >= self.slots.len) return false;

        const slot = &self.slots[handle.slot];
        if (slot.generation.load(.acquire) != handle.generation) return false;
        if (slot.state.cmpxchgStrong(SLOT_USED, SLOT_FREE, .acq_rel, .acquire) != null) {
            return false;
        }

        _ = slot.generation.fetchAdd(1, .release);

        var packed_head = self.free_head.load(.acquire);
        while (true) {
            const head = unpackHead(packed_head);
            slot.next.store(head.slot, .release);
            const updated_head = packHead(.{ .slot = handle.slot, .tag = head.tag +% 1 });
            if (self.free_head.cmpxchgWeak(packed_head, updated_head, .acq_rel, .monotonic)) |updated| {
                packed_head = updated;
                continue;
            }
            return true;
        }
    }

    pub fn available(self: *Self) usize {
        var count: usize = 0;
        var head = unpackHead(self.free_head.load(.acquire)).slot;
        while (head != INVALID_SLOT and count <= self.slots.len) {
            count += 1;
            head = self.slots[head].next.load(.acquire);
        }
        return count;
    }
};

test "payload pool reserve and release" {
    const allocator = std.testing.allocator;

    var pool = try PayloadPool.init(allocator, 2, 16);
    defer pool.deinit();

    const first = pool.reserve(5) orelse return error.ExpectedReservation;
    @memcpy(first.bytes, "hello");
    try std.testing.expectEqualStrings("hello", first.bytes);

    const second = pool.reserve(3) orelse return error.ExpectedReservation;
    try std.testing.expect(pool.reserve(1) == null);

    try std.testing.expect(pool.release(first.handle));
    try std.testing.expect(!pool.release(first.handle));

    const third = pool.reserve(4) orelse return error.ExpectedReservation;
    try std.testing.expect(third.handle.generation != first.handle.generation);

    try std.testing.expect(pool.release(second.handle));
    try std.testing.expect(pool.release(third.handle));
}

test "payload pool concurrent reserve and release preserves exclusive slot ownership" {
    const allocator = std.testing.allocator;
    const slot_count = 32;
    const slot_size = 64;
    const thread_count = 8;
    const iterations = 5000;
    const payload_len = 32;

    var pool = try PayloadPool.init(allocator, slot_count, slot_size);
    defer pool.deinit();

    var in_use: [slot_count]std.atomic.Value(bool) = undefined;
    for (&in_use) |*flag| {
        flag.* = std.atomic.Value(bool).init(false);
    }

    var failures = std.atomic.Value(usize).init(0);
    var successful_ops = std.atomic.Value(usize).init(0);
    var stop = std.atomic.Value(bool).init(false);

    const WorkerContext = struct {
        pool: *PayloadPool,
        in_use: []std.atomic.Value(bool),
        failures: *std.atomic.Value(usize),
        successful_ops: *std.atomic.Value(usize),
        stop: *std.atomic.Value(bool),
        worker_id: usize,
    };

    const Worker = struct {
        fn fail(ctx: WorkerContext) void {
            _ = ctx.failures.fetchAdd(1, .monotonic);
            ctx.stop.store(true, .release);
        }

        fn run(ctx: WorkerContext) void {
            var i: usize = 0;
            while (i < iterations and !ctx.stop.load(.acquire)) : (i += 1) {
                const reservation = while (true) {
                    if (ctx.stop.load(.acquire)) return;
                    if (ctx.pool.reserve(payload_len)) |reservation| break reservation;
                    std.atomic.spinLoopHint();
                };

                if (reservation.handle.slot >= ctx.in_use.len) {
                    fail(ctx);
                    return;
                }

                const flag = &ctx.in_use[reservation.handle.slot];
                if (flag.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
                    // Two threads believe they own the same slot concurrently.
                    fail(ctx);
                    return;
                }

                const pattern: u8 = @truncate((ctx.worker_id * 31) + i);
                @memset(reservation.bytes, pattern);

                var spin: usize = 0;
                while (spin < 16) : (spin += 1) {
                    std.atomic.spinLoopHint();
                }

                for (reservation.bytes) |byte| {
                    if (byte != pattern) {
                        flag.store(false, .release);
                        _ = ctx.pool.release(reservation.handle);
                        fail(ctx);
                        return;
                    }
                }

                flag.store(false, .release);
                if (!ctx.pool.release(reservation.handle)) {
                    fail(ctx);
                    return;
                }

                _ = ctx.successful_ops.fetchAdd(1, .monotonic);
            }
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, worker_id| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{WorkerContext{
            .pool = &pool,
            .in_use = in_use[0..],
            .failures = &failures,
            .successful_ops = &successful_ops,
            .stop = &stop,
            .worker_id = worker_id,
        }});
    }

    for (threads) |thread| {
        thread.join();
    }

    try std.testing.expectEqual(@as(usize, 0), failures.load(.acquire));
    try std.testing.expectEqual(@as(usize, thread_count * iterations), successful_ops.load(.acquire));
    try std.testing.expectEqual(@as(usize, slot_count), pool.available());
}

test "payload pool concurrent stale handle release is rejected" {
    const allocator = std.testing.allocator;
    const thread_count = 8;
    const attempts_per_thread = 1000;

    var pool = try PayloadPool.init(allocator, 1, 16);
    defer pool.deinit();

    const first = pool.reserve(8) orelse return error.ExpectedReservation;
    try std.testing.expect(pool.release(first.handle));

    const second = pool.reserve(8) orelse return error.ExpectedReservation;
    try std.testing.expect(second.handle.generation != first.handle.generation);

    var accepted_stale_releases = std.atomic.Value(usize).init(0);

    const WorkerContext = struct {
        pool: *PayloadPool,
        stale_handle: PayloadHandle,
        accepted_stale_releases: *std.atomic.Value(usize),
    };

    const Worker = struct {
        fn run(ctx: WorkerContext) void {
            var i: usize = 0;
            while (i < attempts_per_thread) : (i += 1) {
                if (ctx.pool.release(ctx.stale_handle)) {
                    _ = ctx.accepted_stale_releases.fetchAdd(1, .monotonic);
                }
                std.atomic.spinLoopHint();
            }
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{WorkerContext{
            .pool = &pool,
            .stale_handle = first.handle,
            .accepted_stale_releases = &accepted_stale_releases,
        }});
    }

    for (threads) |thread| {
        thread.join();
    }

    try std.testing.expectEqual(@as(usize, 0), accepted_stale_releases.load(.acquire));
    try std.testing.expect(pool.release(second.handle));
    try std.testing.expectEqual(@as(usize, 1), pool.available());
}
