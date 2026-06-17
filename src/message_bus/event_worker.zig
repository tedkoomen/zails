const std = @import("std");
const Allocator = std.mem.Allocator;
const Event = @import("../event.zig").Event;
const Subscription = @import("subscriber.zig").Subscription;

// Forward declaration - MessageBus will be available at runtime
pub const MessageBus = @import("message_bus.zig").MessageBus;

/// Background worker for event delivery.
///
/// Each worker pops events from the shared ring buffer and delivers
/// them to matching subscribers sequentially. Sequential delivery
/// avoids the overhead of spawning an OS thread per subscriber per
/// event (~10-50µs per spawn), which dominates at high throughput.
///
/// Uses adaptive polling: busy-spins briefly (1µs), then backs off
/// to short sleeps (100µs). No 100ms sleep — worst-case wake latency
/// is ~100µs, not 100ms.
///
/// Handlers are expected to be fast callbacks. If a handler needs to
/// do expensive work, it should enqueue the work elsewhere.
pub const EventWorker = struct {
    const Self = @This();

    /// Thread-local: subscription ID of the handler currently being invoked.
    /// Set before each handler call, cleared after. When a handler mutates a
    /// ReactiveModel, the model reads this to tag the outgoing event so the
    /// event worker skips delivery back to the originating handler.
    /// Zero means "no handler context" (external publish, all subs receive).
    pub threadlocal var current_handler_subscription_id: u64 = 0;

    id: usize,
    message_bus: *MessageBus,
    config: MessageBus.Config,
    cpu_id: ?usize, // CPU to pin this worker to (null = no affinity)

    pub fn init(id: usize, message_bus: *MessageBus, config: MessageBus.Config) Self {
        return Self{
            .id = id,
            .message_bus = message_bus,
            .config = config,
            .cpu_id = null,
        };
    }

    /// Set CPU affinity for this worker thread
    fn setCpuAffinity(self: *Self) void {
        const total_cpus = std.Thread.getCpuCount() catch 4;
        const message_bus_cpu_start = @min(2, total_cpus / 2);
        self.cpu_id = message_bus_cpu_start + (self.id % (total_cpus - message_bus_cpu_start));

        std.log.info("EventWorker {}: would pin to CPU {} (affinity disabled)", .{ self.id, self.cpu_id.? });
    }

    /// Adaptive backoff: spin briefly, then short sleep.
    /// Max wake latency: ~100µs (vs 100ms before).
    const SPIN_ITERATIONS = 64;
    const BACKOFF_SLEEP_NS = 100_000; // 100µs

    pub fn run(self: *Self) void {
        const allocator = self.message_bus.allocator;

        // Set CPU affinity to isolate from TCP workers
        self.setCpuAffinity();

        std.log.info("EventWorker {} started on CPU {?}", .{ self.id, self.cpu_id });

        var empty_spins: u32 = 0;

        while (!self.message_bus.shutdown.load(.acquire)) {
            // Pop event from queue
            const event = self.message_bus.event_queue.pop() orelse {
                // Adaptive backoff: spin briefly, then sleep 100µs
                empty_spins +|= 1;
                if (empty_spins < SPIN_ITERATIONS) {
                    std.atomic.spinLoopHint();
                } else {
                    std.Thread.sleep(BACKOFF_SLEEP_NS);
                }
                continue;
            };

            // Reset spin counter on successful pop
            empty_spins = 0;

            // Zero-allocation matching via stack result
            const match_result = self.message_bus.subscribers.getMatchingResult(&event);
            const subscribers = match_result.slice();

            // Sequential delivery — fast callbacks, no thread spawn overhead.
            // Before calling each handler, set the thread-local so that any
            // ReactiveModel mutation inside the handler tags its outgoing event
            // with this subscription ID. After delivery, the event worker
            // checks source_subscription_id and skips the originating handler.
            for (subscribers) |sub| {
                // Skip delivery back to the subscription that caused this event
                if (event.source_subscription_id != 0 and sub.id == event.source_subscription_id) {
                    continue;
                }
                current_handler_subscription_id = sub.id;
                defer current_handler_subscription_id = 0;
                sub.handler(&event, allocator);
                _ = self.message_bus.total_delivered.fetchAdd(1, .monotonic);
            }

            event.deinit(allocator);
        }

        std.log.info("EventWorker {} stopped", .{self.id});
    }
};
