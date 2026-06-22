const std = @import("std");
const Event = @import("event.zig").Event;
const Filter = @import("message_bus/filter.zig").Filter;
const MessageBus = @import("message_bus/message_bus.zig").MessageBus;

var delivered = std.atomic.Value(u64).init(0);
var allocation_backing: [8 * 1024 * 1024]u8 = undefined;
var fragmentation_backing: [16 * 1024 * 1024]u8 = undefined;

fn probeHandler(event: *const Event, allocator: std.mem.Allocator) void {
    _ = event;
    _ = allocator;
    _ = delivered.fetchAdd(1, .monotonic);
}

const FragmentationMetrics = struct {
    total_free: usize,
    largest_free: usize,
    free_blocks: usize,
    fragmentation_pct: usize,
};

const FragmentingHeap = struct {
    const Self = @This();
    const max_blocks = 16_384;

    const Block = struct {
        start: usize = 0,
        len: usize = 0,
        active: bool = false,
    };

    buffer: []u8,
    blocks: [max_blocks]Block = [_]Block{.{}} ** max_blocks,

    pub fn init(buffer: []u8) Self {
        var self = Self{ .buffer = buffer };
        self.blocks[0] = .{ .start = 0, .len = buffer.len, .active = true };
        return self;
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (len == 0) return self.buffer.ptr;

        const base = @intFromPtr(self.buffer.ptr);
        for (&self.blocks) |*block| {
            if (!block.active) continue;

            const aligned_abs = alignment.forward(base + block.start);
            const aligned_start = aligned_abs - base;
            const padding = aligned_start - block.start;
            if (padding > block.len or len > block.len - padding) continue;

            const old_start = block.start;
            const old_len = block.len;
            const suffix_start = aligned_start + len;
            const suffix_len = (old_start + old_len) - suffix_start;

            if (padding > 0) {
                block.* = .{ .start = old_start, .len = padding, .active = true };
                if (suffix_len > 0) _ = self.addFreeBlock(suffix_start, suffix_len) catch return null;
            } else if (suffix_len > 0) {
                block.* = .{ .start = suffix_start, .len = suffix_len, .active = true };
            } else {
                block.active = false;
                block.len = 0;
            }

            return self.buffer[aligned_start .. aligned_start + len].ptr;
        }

        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        if (memory.len == 0) return;

        const self: *Self = @ptrCast(@alignCast(ctx));
        const base = @intFromPtr(self.buffer.ptr);
        const start = @intFromPtr(memory.ptr) - base;
        const block_index = self.addFreeBlock(start, memory.len) catch @panic("fragmenting heap free-list exhausted");
        self.coalesceFrom(block_index);
    }

    fn addFreeBlock(self: *Self, start: usize, len: usize) !usize {
        if (len == 0) return 0;
        for (&self.blocks, 0..) |*block, i| {
            if (!block.active) {
                block.* = .{ .start = start, .len = len, .active = true };
                return i;
            }
        }
        return error.FreeListFull;
    }

    fn coalesceFrom(self: *Self, initial_index: usize) void {
        if (initial_index >= self.blocks.len or !self.blocks[initial_index].active) return;

        const index = initial_index;
        var changed = true;
        while (changed) {
            changed = false;

            for (&self.blocks, 0..) |*other, other_index| {
                if (other_index == index or !other.active) continue;

                const current = &self.blocks[index];
                if (current.start + current.len == other.start) {
                    current.len += other.len;
                    other.active = false;
                    other.len = 0;
                    changed = true;
                    break;
                }

                if (other.start + other.len == current.start) {
                    current.start = other.start;
                    current.len += other.len;
                    other.active = false;
                    other.len = 0;
                    changed = true;
                    break;
                }
            }
        }
    }

    fn metrics(self: *const Self) FragmentationMetrics {
        var total_free: usize = 0;
        var largest_free: usize = 0;
        var free_blocks: usize = 0;

        for (&self.blocks) |*block| {
            if (!block.active) continue;
            free_blocks += 1;
            total_free += block.len;
            largest_free = @max(largest_free, block.len);
        }

        const fragmentation_pct = if (total_free == 0)
            0
        else
            100 - ((largest_free * 100) / total_free);

        return .{
            .total_free = total_free,
            .largest_free = largest_free,
            .free_blocks = free_blocks,
            .fragmentation_pct = fragmentation_pct,
        };
    }
};

fn runHotPathProbe(allocator: std.mem.Allocator, iterations: usize) !u64 {
    delivered.store(0, .release);

    var bus = try MessageBus.init(allocator, .{
        .queue_capacity = 1024,
        .worker_count = 1,
        .payload_pool_slot_size = 256,
    });
    defer bus.deinit();

    const filter = Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gt, .value = "100" },
        },
    };
    const sub_id = try bus.subscribe("Probe.created", filter, probeHandler);
    defer bus.unsubscribe(sub_id);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var data_buf: [64]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buf, "{{\"id\":{d}}}", .{i});

        var event = Event{
            .id = @intCast(i),
            .timestamp = @intCast(i),
            .event_type = .custom,
            .topic = "Probe.created",
            .model_type = "Probe",
            .model_id = @intCast(i),
            .data = data,
        };
        event.setField("price", .{ .int = 101 });

        if (!bus.publish(event)) return error.PublishUnexpectedlyDropped;
        @memset(data_buf[0..data.len], 'x');

        const popped = bus.event_queue.pop() orelse return error.RingUnexpectedlyEmpty;

        var matches = bus.subscribers.matchingIterator(&popped);
        while (matches.next()) |sub| {
            sub.handler(&popped, allocator);
        }
        popped.deinit(allocator);
    }

    return delivered.load(.acquire);
}

fn fragmentHeap(allocator: std.mem.Allocator) !void {
    const small_count = 4096;
    const filler_count = 512;

    var small: [small_count]?[]u8 = [_]?[]u8{null} ** small_count;
    var fillers: [filler_count]?[]u8 = [_]?[]u8{null} ** filler_count;

    for (&small, 0..) |*slot, i| {
        const size = 32 + ((i * 37) % 992);
        slot.* = try allocator.alloc(u8, size);
    }

    for (&small, 0..) |*slot, i| {
        if (i % 2 == 0) {
            if (slot.*) |bytes| allocator.free(bytes);
            slot.* = null;
        }
    }

    for (&fillers, 0..) |*slot, i| {
        const size = 24 * 1024 + ((i * 4099) % (16 * 1024));
        slot.* = allocator.alloc(u8, size) catch null;
    }

    // Keep every odd small allocation and the tail fillers live. That consumes
    // the large contiguous tail while leaving thousands of interleaved holes,
    // so the probe exercises a fragmented heap rather than a clean arena.
}

pub fn main() !void {
    var fixed = std.heap.FixedBufferAllocator.init(&allocation_backing);
    const clean_delivered = try runHotPathProbe(fixed.allocator(), 100_000);
    std.debug.print("allocation_probe clean delivered={d}\n", .{clean_delivered});

    var fragmented = FragmentingHeap.init(&fragmentation_backing);
    const fragmented_allocator = fragmented.allocator();

    var bus = try MessageBus.init(fragmented_allocator, .{
        .queue_capacity = 1024,
        .worker_count = 1,
        .payload_pool_slot_size = 256,
    });
    defer bus.deinit();

    try fragmentHeap(fragmented_allocator);
    const before = fragmented.metrics();
    if (before.fragmentation_pct < 50 or before.free_blocks < 100) {
        return error.FragmentationScenarioTooWeak;
    }

    delivered.store(0, .release);
    const filter = Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gt, .value = "100" },
        },
    };
    const sub_id = try bus.subscribe("Probe.created", filter, probeHandler);
    defer bus.unsubscribe(sub_id);

    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        var data_buf: [64]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buf, "{{\"id\":{d}}}", .{i});

        var event = Event{
            .id = @intCast(i),
            .timestamp = @intCast(i),
            .event_type = .custom,
            .topic = "Probe.created",
            .model_type = "Probe",
            .model_id = @intCast(i),
            .data = data,
        };
        event.setField("price", .{ .int = 101 });

        if (!bus.publish(event)) return error.PublishUnexpectedlyDropped;
        @memset(data_buf[0..data.len], 'x');

        const popped = bus.event_queue.pop() orelse return error.RingUnexpectedlyEmpty;

        var matches = bus.subscribers.matchingIterator(&popped);
        while (matches.next()) |sub| {
            sub.handler(&popped, fragmented_allocator);
        }
        popped.deinit(fragmented_allocator);
    }

    const after = fragmented.metrics();
    std.debug.print(
        "allocation_probe fragmented delivered={d} free_blocks={d} total_free={d} largest_free={d} fragmentation={d}% after_fragmentation={d}%\n",
        .{
            delivered.load(.acquire),
            before.free_blocks,
            before.total_free,
            before.largest_free,
            before.fragmentation_pct,
            after.fragmentation_pct,
        },
    );
}
