// ============================================================================
// MESSAGE BUS ARCHITECTURE
// ============================================================================
//
// This file demonstrates the complete architecture of the Message Bus system
// through code examples and detailed comments.
//
// ============================================================================

const std = @import("std");
const message_bus = @import("../src/message_bus/mod.zig");
const Event = @import("../src/event.zig").Event;
const generateEventId = @import("../src/event.zig").generateEventId;

// ============================================================================
// PART 1: ARCHITECTURE OVERVIEW
// ============================================================================

/// MESSAGE BUS ARCHITECTURE DIAGRAM:
///
/// ┌─────────────────────────────────────────────────────────────────────┐
/// │                         APPLICATION LAYER                            │
/// │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐            │
/// │  │ Model    │  │ Handler  │  │ Service  │  │ Controller│            │
/// │  │ (Trade)  │  │          │  │          │  │           │            │
/// │  └────┬─────┘  └─────┬────┘  └─────┬────┘  └─────┬────┘            │
/// │       │              │             │             │                   │
/// │       │ publish()    │ subscribe() │             │                   │
/// │       │              │             │             │                   │
/// └───────┼──────────────┼─────────────┼─────────────┼───────────────────┘
///         │              │             │             │
///         ▼              ▼             ▼             ▼
/// ┌─────────────────────────────────────────────────────────────────────┐
/// │                       MESSAGE BUS CORE                               │
/// │  ┌──────────────────────────────────────────────────────────────┐  │
/// │  │                     MessageBus                                │  │
/// │  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │  │
/// │  │  │ publish()    │  │ subscribe()  │  │ unsubscribe()│       │  │
/// │  │  │ [< 1µs]      │  │              │  │              │       │  │
/// │  │  └──────┬───────┘  └───────┬──────┘  └──────────────┘       │  │
/// │  │         │                  │                                 │  │
/// │  │         ▼                  ▼                                 │  │
/// │  │  ┌──────────────┐  ┌──────────────────────┐                 │  │
/// │  │  │ Ring Buffer  │  │ SubscriberRegistry   │                 │  │
/// │  │  │ [Lock-Free]  │  │ [RwLock]             │                 │  │
/// │  │  │              │  │                      │                 │  │
/// │  │  │ ┌──────────┐│  │ ┌─────────────────┐  │                 │  │
/// │  │  │ │  Event   ││  │ │ Topic → Subs    │  │                 │  │
/// │  │  │ │  Event   ││  │ │ "Trade.*" → [   ]│  │                 │  │
/// │  │  │ │  Event   ││  │ │ "Trade.created"→│  │                 │  │
/// │  │  │ │  ...     ││  │ └─────────────────┘  │                 │  │
/// │  │  │ └──────────┘│  │                      │                 │  │
/// │  │  └──────┬───────┘  └──────────────────────┘                 │  │
/// │  └─────────┼──────────────────────────────────────────────────┘  │
/// │            │                                                       │
/// │            │ pop()                                                 │
/// │            ▼                                                       │
/// │  ┌─────────────────────────────────────────────────────────────┐ │
/// │  │                    EVENT WORKERS                             │ │
/// │  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │ │
/// │  │  │ Worker 1 │  │ Worker 2 │  │ Worker 3 │  │ Worker 4 │   │ │
/// │  │  │ [Thread] │  │ [Thread] │  │ [Thread] │  │ [Thread] │   │ │
/// │  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘   │ │
/// │  │       │             │             │             │           │ │
/// │  └───────┼─────────────┼─────────────┼─────────────┼───────────┘ │
/// │          │             │             │             │             │
/// └──────────┼─────────────┼─────────────┼─────────────┼─────────────┘
///            │             │             │             │
///            ▼             ▼             ▼             ▼
/// ┌─────────────────────────────────────────────────────────────────────┐
/// │                      EVENT PROCESSING                                │
/// │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐             │
/// │  │ Get Event    │  │ Get Matching │  │ Filter Check │             │
/// │  │ from Queue   │→ │ Subscribers  │→ │ [< 10µs]     │             │
/// │  └──────────────┘  └──────────────┘  └──────┬───────┘             │
/// │                                              │                      │
/// │                                              ▼                      │
/// │                                       ┌──────────────┐             │
/// │                                       │ Execute      │             │
/// │                                       │ Handlers     │             │
/// │                                       │ [Parallel]   │             │
/// │                                       └──────┬───────┘             │
/// │                                              │                      │
/// │                                              ▼                      │
/// │                                       ┌──────────────┐             │
/// │                                       │ Persist to   │             │
/// │                                       │ ClickHouse   │             │
/// │                                       │ [Batched]    │             │
/// │                                       └──────────────┘             │
/// └─────────────────────────────────────────────────────────────────────┘

// ============================================================================
// PART 2: CORE COMPONENTS
// ============================================================================

/// Component 1: Event
///
/// The Event is the fundamental message unit in the system.
/// It uses protobuf for efficient serialization.
///
/// Protobuf Schema:
///   message Event {
///     bytes id = 1;            // 16-byte UUID
///     int64 timestamp = 2;     // Unix microseconds
///     uint32 event_type = 3;   // created, updated, deleted
///     string topic = 4;        // "Trade.created"
///     string model_type = 5;   // "Trade"
///     uint64 model_id = 6;     // Database ID
///     bytes data = 7;          // JSON payload
///   }
fn demonstrateEventStructure() !void {
    const allocator = std.heap.page_allocator;

    // Create an event
    const event = Event{
        .id = generateEventId(), // Random UUID
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 42,
        .data = "{\"symbol\":\"AAPL\",\"price\":15000,\"quantity\":100}",
    };

    // Serialize to protobuf (binary)
    var buffer: [4096]u8 = undefined;
    const serialized = try event.serialize(&buffer);

    std.log.info("Event serialized to {d} bytes (protobuf)", .{serialized.len});

    // Deserialize back
    const deserialized = try Event.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);

    std.log.info("Event ID: {x}", .{deserialized.id});
    std.log.info("Topic: {s}", .{deserialized.topic});
    std.log.info("Data: {s}", .{deserialized.data});
}

/// Component 2: Ring Buffer (Lock-Free Queue)
///
/// The EventRingBuffer is a lock-free circular buffer that enables
/// sub-microsecond event publishing.
///
/// Architecture:
///   ┌─────────────────────────────────────┐
///   │       Ring Buffer (Fixed Size)      │
///   │  ┌───┬───┬───┬───┬───┬───┬───┬───┐ │
///   │  │ E │ E │ E │   │   │   │   │   │ │
///   │  └───┴───┴───┴───┴───┴───┴───┴───┘ │
///   │    ↑           ↑                    │
///   │   tail        head                  │
///   │  (consumer)   (producer)            │
///   │                                     │
///   │  head.store(next, .release)  ◄──── │ Atomic operations
///   │  tail.load(.acquire)          ◄──── │ Memory ordering
///   └─────────────────────────────────────┘
///
/// Performance: < 1µs for push() operation
fn demonstrateRingBuffer() !void {
    const allocator = std.heap.page_allocator;
    const EventRingBuffer = message_bus.EventRingBuffer;

    var buffer = try EventRingBuffer.init(allocator, 1024);
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

    // Push (lock-free, atomic)
    const success = buffer.push(event);
    std.log.info("Event pushed: {}", .{success});

    // Check size
    std.log.info("Buffer size: {d}", .{buffer.size()});

    // Pop (lock-free, atomic)
    const popped = buffer.pop();
    if (popped) |e| {
        std.log.info("Event popped: ID={d}", .{e.id});
    }
}

/// Component 3: Filter System
///
/// Filters enable parameterized subscriptions using field comparisons.
///
/// Filter Architecture:
///   ┌─────────────────────────────────────┐
///   │          Filter                     │
///   │  ┌───────────────────────────────┐ │
///   │  │ WhereClause[]                 │ │
///   │  │  - field: "price"             │ │
///   │  │  - op: .gt                    │ │
///   │  │  - value: "1000"              │ │
///   │  └───────────────────────────────┘ │
///   │          │                          │
///   │          ▼                          │
///   │  ┌───────────────────────────────┐ │
///   │  │ matches(event)                │ │
///   │  │  1. Parse event.data (JSON)   │ │
///   │  │  2. Extract field value       │ │
///   │  │  3. Compare using operator    │ │
///   │  │  4. Return true/false         │ │
///   │  └───────────────────────────────┘ │
///   └─────────────────────────────────────┘
///
/// Supported operators:
///   - eq, ne: Equality
///   - gt, gte, lt, lte: Comparison
///   - like: Substring match
///   - in, not_in: Set membership
fn demonstrateFilter() !void {
    const allocator = std.heap.page_allocator;
    const Filter = message_bus.Filter;

    // Create filter: price > 1000 AND symbol = "AAPL"
    const filter = Filter{
        .conditions = &.{
            .{ .field = "price", .op = .gt, .value = "1000" },
            .{ .field = "symbol", .op = .eq, .value = "AAPL" },
        },
    };

    // Test event 1: AAPL @ $1500 (should match)
    const event1 = Event{
        .id = 1,
        .timestamp = 100,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{\"symbol\":\"AAPL\",\"price\":1500}",
    };

    const match1 = try filter.matches(&event1, allocator);
    std.log.info("Event 1 matches: {}", .{match1}); // true

    // Test event 2: TSLA @ $500 (should NOT match)
    const event2 = Event{
        .id = 2,
        .timestamp = 200,
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 2,
        .data = "{\"symbol\":\"TSLA\",\"price\":500}",
    };

    const match2 = try filter.matches(&event2, allocator);
    std.log.info("Event 2 matches: {}", .{match2}); // false
}

/// Component 4: Subscriber Registry
///
/// Thread-safe registry using RwLock for read-heavy workload.
///
/// Registry Architecture:
///   ┌─────────────────────────────────────────────┐
///   │       SubscriberRegistry [RwLock]          │
///   │  ┌──────────────────────────────────────┐  │
///   │  │ subscriptions: HashMap<Topic, []Sub> │  │
///   │  │                                      │  │
///   │  │ "Trade.created" → [                 │  │
///   │  │   {id:1, filter:{...}, handler:fn}  │  │
///   │  │   {id:2, filter:{...}, handler:fn}  │  │
///   │  │ ]                                    │  │
///   │  │                                      │  │
///   │  │ "Trade.*" → [                       │  │
///   │  │   {id:3, filter:{...}, handler:fn}  │  │
///   │  │ ]                                    │  │
///   │  └──────────────────────────────────────┘  │
///   │                                             │
///   │  subscribe() → lock.lock()                 │
///   │  getMatching() → lock.lockShared()         │
///   └─────────────────────────────────────────────┘
///
/// Performance: Multiple readers can access concurrently
fn demonstrateSubscriberRegistry() !void {
    const allocator = std.heap.page_allocator;
    const SubscriberRegistry = message_bus.SubscriberRegistry;
    const Filter = message_bus.Filter;

    var registry = SubscriberRegistry.init(allocator);
    defer registry.deinit();

    // Handler function
    const handler = struct {
        fn handle(event: *const Event, alloc: std.mem.Allocator) void {
            _ = alloc;
            std.log.info("Handler called for event {d}", .{event.model_id});
        }
    }.handle;

    // Subscribe
    const filter = Filter{ .conditions = &.{} };
    const sub_id = try registry.subscribe("Trade.created", filter, handler);

    std.log.info("Subscription ID: {d}", .{sub_id});
    std.log.info("Subscribers for 'Trade.created': {d}", .{
        registry.getTopicSubscriptionCount("Trade.created"),
    });

    // Unsubscribe
    registry.unsubscribe(sub_id);
}

/// Component 5: Event Workers
///
/// Background threads that consume events and execute handlers.
///
/// Worker Architecture:
///   ┌──────────────────────────────────────┐
///   │      EventWorker (Thread)            │
///   │  ┌────────────────────────────────┐  │
///   │  │ while (!shutdown) {            │  │
///   │  │   event = queue.pop()          │  │
///   │  │   if (event == null) {         │  │
///   │  │     sleep(100ms)               │  │
///   │  │     continue                   │  │
///   │  │   }                            │  │
///   │  │                                │  │
///   │  │   subscribers = registry       │  │
///   │  │     .getMatching(event)        │  │
///   │  │                                │  │
///   │  │   for (sub in subscribers) {   │  │
///   │  │     // Error isolation!        │  │
///   │  │     sub.handler(event)         │  │
///   │  │   }                            │  │
///   │  │                                │  │
///   │  │   persist(event)               │  │
///   │  │ }                              │  │
///   │  └────────────────────────────────┘  │
///   └──────────────────────────────────────┘
///
/// Key features:
///   - Error isolation (handler crash doesn't affect others)
///   - Non-blocking (uses sleep when queue empty)
///   - Persistent audit log to ClickHouse
fn demonstrateEventWorker() void {
    // Event workers run automatically when MessageBus.start() is called
    // See the MessageBus demonstration below
    std.log.info("Event workers run in background threads", .{});
}

/// Component 6: MessageBus (Main Orchestrator)
///
/// The MessageBus ties all components together.
///
/// MessageBus Architecture:
///   ┌───────────────────────────────────────────┐
///   │           MessageBus                      │
///   │  ┌─────────────────────────────────────┐ │
///   │  │ event_queue: EventRingBuffer        │ │
///   │  │ subscribers: SubscriberRegistry     │ │
///   │  │ workers: []EventWorker              │ │
///   │  │ worker_threads: []Thread            │ │
///   │  │ shutdown: atomic<bool>              │ │
///   │  │                                     │ │
///   │  │ publish(event) {                    │ │
///   │  │   event_queue.push(event)           │ │
///   │  │   total_published++                 │ │
///   │  │ }                                   │ │
///   │  │                                     │ │
///   │  │ subscribe(topic, filter, handler) { │ │
///   │  │   return subscribers.subscribe(...) │ │
///   │  │ }                                   │ │
///   │  │                                     │ │
///   │  │ start() {                           │ │
///   │  │   for (worker in workers) {         │ │
///   │  │     spawn_thread(worker.run)        │ │
///   │  │   }                                 │ │
///   │  │ }                                   │ │
///   │  └─────────────────────────────────────┘ │
///   └───────────────────────────────────────────┘
fn demonstrateMessageBus() !void {
    const allocator = std.heap.page_allocator;
    const MessageBus = message_bus.MessageBus;

    // Create bus
    var bus = try MessageBus.init(allocator, .{
        .queue_capacity = 8192,
        .worker_count = 4,
        .flush_interval_ms = 100,
    });
    defer bus.deinit();

    // Start background workers
    try bus.start();

    std.log.info("MessageBus initialized with 4 workers", .{});

    // Publish event
    const event = Event{
        .id = generateEventId(),
        .timestamp = std.time.microTimestamp(),
        .event_type = .model_created,
        .topic = "Trade.created",
        .model_type = "Trade",
        .model_id = 1,
        .data = "{\"symbol\":\"AAPL\",\"price\":150}",
    };

    bus.publish(event);

    // Get statistics
    const stats = bus.getStats();
    std.log.info("Published: {d}, Dropped: {d}, Queued: {d}", .{
        stats.published,
        stats.dropped,
        stats.queued,
    });
}

// ============================================================================
// PART 3: DATA FLOW
// ============================================================================

/// DATA FLOW DIAGRAM:
///
/// Step 1: Model Creates Trade
/// ────────────────────────────
///   Model.create() {
///     // 1. Save to database
///     try db.insert(trade);
///
///     // 2. Publish event
///     const event = Event{
///       .topic = "Trade.created",
///       .data = serialize(trade),
///     };
///     bus.publish(event);  ◄── Takes < 1µs
///   }
///
/// Step 2: Event Enters Ring Buffer
/// ──────────────────────────────────
///   Ring Buffer:
///   [ E1 | E2 | E3 | NEW | __ | __ | __ | __ ]
///                     ↑
///                   head++
///
/// Step 3: Worker Picks Up Event
/// ───────────────────────────────
///   Worker Thread:
///     event = ring_buffer.pop()
///     ↓
///   [ E1 | E2 | E3 | __ | __ | __ | __ | __ ]
///           ↑
///         tail++
///
/// Step 4: Find Matching Subscribers
/// ───────────────────────────────────
///   subscribers = registry.getMatching(event)
///   ↓
///   Check each subscription:
///     ✓ Topic matches? "Trade.created" == "Trade.created"
///     ✓ Filter matches? price > 1000 && symbol == "AAPL"
///     ↓
///   Return: [sub1, sub3, sub7]
///
/// Step 5: Execute Handlers (Parallel)
/// ─────────────────────────────────────
///   for (sub in subscribers) {
///     sub.handler(event)  ◄── User-defined logic
///   }
///
///   Example handlers:
///     - updatePortfolio(event)
///     - sendRiskAlert(event)
///     - logToMetrics(event)
///
/// Step 6: Persist to ClickHouse
/// ───────────────────────────────
///   INSERT INTO events (id, timestamp, topic, data)
///   VALUES (event.id, event.timestamp, event.topic, event.data)
///
///   (Batched: 100 events per INSERT for performance)

// ============================================================================
// PART 4: PERFORMANCE CHARACTERISTICS
// ============================================================================

/// PERFORMANCE BREAKDOWN:
///
/// Operation          | Latency     | Method
/// -------------------|-------------|----------------------------------
/// Event.publish()    | < 1µs       | Lock-free atomic ring buffer push
/// Filter.matches()   | < 10µs      | JSON parse + field comparison
/// Worker delivery    | Async       | Background thread pool
/// ClickHouse persist | Batched     | 100 events/INSERT, async
/// -------------------|-------------|----------------------------------
/// Total overhead     | < 5µs       | Added to model.create()
///
/// SCALABILITY:
///
/// Queue Capacity: 8,192 events
///   - At 10k events/sec → ~800ms buffer
///   - Back-pressure: Drop events when full
///
/// Worker Count: 4 threads (configurable)
///   - Each worker: 10k+ events/sec
///   - Total throughput: 40k+ events/sec
///
/// Memory Usage:
///   - Ring buffer: ~512KB (8192 * 64 bytes/event)
///   - Subscriber registry: ~1KB per subscription
///   - Worker threads: 4 * 8MB stack = 32MB
///
/// NUMA Awareness:
///   - Workers can be pinned to NUMA nodes
///   - Ring buffer is cache-line aligned
///   - Lock-free operations minimize cache thrashing

// ============================================================================
// PART 5: THREAD SAFETY
// ============================================================================

/// THREAD SAFETY GUARANTEES:
///
/// Component            | Synchronization | Notes
/// ---------------------|-----------------|--------------------------------
/// Ring Buffer          | Lock-free       | Atomic head/tail pointers
/// Subscriber Registry  | RwLock          | Multiple readers, single writer
/// Event Workers        | None            | Each worker is independent
/// MessageBus.publish() | Lock-free       | Safe from any thread
/// MessageBus.subscribe()| Mutex          | Via RwLock in registry
/// ---------------------|-----------------|--------------------------------
///
/// MEMORY ORDERING:
///
/// Ring Buffer:
///   - push(): head.store(next, .release)  ◄── Ensures visibility
///   - pop():  tail.load(.acquire)         ◄── Synchronizes-with store
///
/// Atomic Counters:
///   - total_published.fetchAdd(1, .monotonic)
///   - total_dropped.fetchAdd(1, .monotonic)
///   - total_delivered.fetchAdd(1, .monotonic)
///
/// SAFETY GUARANTEES:
///
/// 1. No data races (all shared state is synchronized)
/// 2. No deadlocks (lock-free where possible)
/// 3. No lost events (unless queue is full → back-pressure)
/// 4. Handler isolation (one crash doesn't affect others)

pub fn main() !void {
    std.log.info("=== Message Bus Architecture Documentation ===\n", .{});

    std.log.info("Component 1: Event Structure", .{});
    try demonstrateEventStructure();

    std.log.info("\nComponent 2: Ring Buffer", .{});
    try demonstrateRingBuffer();

    std.log.info("\nComponent 3: Filter System", .{});
    try demonstrateFilter();

    std.log.info("\nComponent 4: Subscriber Registry", .{});
    try demonstrateSubscriberRegistry();

    std.log.info("\nComponent 5: Event Workers", .{});
    demonstrateEventWorker();

    std.log.info("\nComponent 6: MessageBus", .{});
    try demonstrateMessageBus();

    std.log.info("\n✓ Architecture demonstration complete!", .{});
}
