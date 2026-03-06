const std = @import("std");
const Allocator = std.mem.Allocator;
const Event = @import("../event.zig").Event;
const Subscription = @import("subscriber.zig").Subscription;

// Forward declaration - MessageBus will be available at runtime
pub const MessageBus = @import("message_bus.zig").MessageBus;

/// Background worker for event delivery
pub const EventWorker = struct {
    const Self = @This();

    id: usize,
    message_bus: *MessageBus,
    config: MessageBus.Config,
    cpu_id: ?usize, // CPU to pin this worker to (null = no affinity)

    pub fn init(id: usize, message_bus: *MessageBus, config: MessageBus.Config) Self {
        return Self{
            .id = id,
            .message_bus = message_bus,
            .config = config,
            .cpu_id = null, // Will be set when worker is started
        };
    }

    /// Set CPU affinity for this worker thread
    /// NOTE: CPU affinity requires syscall interface that varies by Zig version.
    /// For production use, implement via C binding or libc.
    fn setCpuAffinity(self: *Self) void {
        const total_cpus = std.Thread.getCpuCount() catch 4;
        const message_bus_cpu_start = @min(2, total_cpus / 2);
        self.cpu_id = message_bus_cpu_start + (self.id % (total_cpus - message_bus_cpu_start));

        std.log.info("EventWorker {}: would pin to CPU {} (affinity disabled)", .{self.id, self.cpu_id.?});
    }

    pub fn run(self: *Self) void {
        const allocator = self.message_bus.allocator;

        // Set CPU affinity to isolate from TCP workers
        self.setCpuAffinity();

        std.log.info("EventWorker {} started on CPU {?}", .{self.id, self.cpu_id});

        while (!self.message_bus.shutdown.load(.acquire)) {
            // Pop event from queue
            const event = self.message_bus.event_queue.pop() orelse {
                // Queue empty - sleep briefly
                std.Thread.sleep(self.config.flush_interval_ms * std.time.ns_per_ms);
                continue;
            };

            const subscribers = self.message_bus.subscribers.getMatching(&event, allocator) catch |err| {
                std.log.err("Worker {}: Failed to get subscribers: {}", .{ self.id, err });
                event.deinit(allocator);
                continue;
            };
            defer allocator.free(subscribers);

            self.deliverParallel(&event, subscribers, allocator);

            std.log.debug("Worker {}: Event delivered - topic={s} subscribers={d}", .{
                self.id,
                event.topic,
                subscribers.len,
            });

            event.deinit(allocator);
        }

        std.log.info("EventWorker {} stopped", .{self.id});
    }

    const HandlerContext = struct {
        worker_id: usize,
        event: *const Event,
        subscription: *const Subscription,
        allocator: Allocator,
        message_bus: *MessageBus,
    };

    fn handlerThreadFn(context: HandlerContext) void {
        context.subscription.handler(context.event, context.allocator);
        _ = context.message_bus.total_delivered.fetchAdd(1, .monotonic);

        std.log.debug("Worker {}: Delivered to subscription {d} [parallel]", .{
            context.worker_id,
            context.subscription.id,
        });
    }

    fn deliverParallel(
        self: *Self,
        event: *const Event,
        subscribers: []const Subscription,
        allocator: Allocator,
    ) void {
        if (subscribers.len == 0) return;

        if (subscribers.len == 1) {
            subscribers[0].handler(event, allocator);
            _ = self.message_bus.total_delivered.fetchAdd(1, .monotonic);
            return;
        }

        const threads = allocator.alloc(std.Thread, subscribers.len) catch {
            std.log.err("Worker {}: Failed to allocate threads, falling back to sequential", .{self.id});
            for (subscribers) |sub| {
                sub.handler(event, allocator);
                _ = self.message_bus.total_delivered.fetchAdd(1, .monotonic);
            }
            return;
        };
        defer allocator.free(threads);

        var spawned_count: usize = 0;
        for (subscribers) |*sub| {
            const context = HandlerContext{
                .worker_id = self.id,
                .event = event,
                .subscription = sub,
                .allocator = allocator,
                .message_bus = self.message_bus,
            };

            threads[spawned_count] = std.Thread.spawn(.{}, handlerThreadFn, .{context}) catch {
                std.log.err("Worker {}: Failed to spawn handler thread, executing inline", .{self.id});
                sub.handler(event, allocator);
                _ = self.message_bus.total_delivered.fetchAdd(1, .monotonic);
                continue;
            };
            spawned_count += 1;
        }

        for (threads[0..spawned_count]) |thread| {
            thread.join();
        }
    }
};
