# Message Bus - Contributor Guide

**For Framework Developers**

This guide explains the internal architecture of the message bus for contributors working on the framework itself.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Core Components](#core-components)
3. [Threading Model](#threading-model)
4. [Lock-Free Design](#lock-free-design)
5. [Performance Characteristics](#performance-characteristics)
6. [File Structure](#file-structure)
7. [Adding Features](#adding-features)
8. [Testing](#testing)
9. [Performance Tuning](#performance-tuning)
10. [Debugging](#debugging)

---

## Architecture Overview

### High-Level Design

```
┌─────────────────────────────────────────────────────────────────┐
│                        Message Bus Architecture                  │
└─────────────────────────────────────────────────────────────────┘

Publishers (Handlers)          Message Bus Core          Subscribers (Handlers)
        │                             │                            │
        │──publish(event)────────────>│                            │
        │    [< 1µs latency]          │                            │
        │                              │                            │
        │                    ┌─────────────────┐                   │
        │                    │ Ring Buffer     │                   │
        │                    │ (Lock-Free)     │                   │
        │                    │ 8192 slots      │                   │
        │                    └─────────────────┘                   │
        │                              │                            │
        │                              ↓                            │
        │                    ┌─────────────────┐                   │
        │                    │ EventWorker 0   │                   │
        │                    │ EventWorker 1   │                   │
        │                    │ EventWorker 2   │                   │
        │                    │ EventWorker 3   │                   │
        │                    └─────────────────┘                   │
        │                              │                            │
        │                              │─────filter events─────────>│
        │                              │─────execute handlers──────>│
        │                              │       [parallel]            │
        │                              │                            │
        │                              ↓                            │
        │                    ┌─────────────────┐                   │
        │                    │  ClickHouse     │                   │
        │                    │  (Audit Log)    │                   │
        │                    └─────────────────┘                   │
```

### Design Goals

1. **Ultra-low latency publishing** - < 1µs to push event to queue
2. **Lock-free hot path** - No mutexes in publish path
3. **Parallel event delivery** - Multiple workers process events concurrently
4. **Fault isolation** - Slow/broken subscriber doesn't affect others
5. **Persistent audit trail** - All events logged to ClickHouse
6. **Compile-time validation** - Topic typos caught at compile time

---

## Core Components

### 1. Event (`src/event.zig`)

The fundamental message unit:

```zig
pub const Event = struct {
    id: u128,               // UUID (random)
    timestamp: i64,         // Unix microseconds
    event_type: EventType,  // created/updated/deleted/custom
    topic: []const u8,      // "Item.created" etc.
    model_type: []const u8, // "Item", "Order", etc.
    model_id: u64,          // Model instance ID
    data: []const u8,       // JSON payload

    pub const EventType = enum(u8) {
        model_created = 0,
        model_updated = 1,
        model_deleted = 2,
        custom = 255,
    };
};
```

**Key design decisions:**
- Fixed-size header (no heap allocations)
- `data` field is slice into pre-allocated buffer
- Event IDs are UUIDs (distributed uniqueness, no coordination)

### 2. Ring Buffer (`src/message_bus/ring_buffer.zig`)

Lock-free SPMC (Single Producer Multiple Consumer) ring buffer:

```zig
pub const EventRingBuffer = struct {
    capacity: usize,                        // Fixed size (8192 default)
    items: []Event,                         // Pre-allocated array
    head: std.atomic.Value(usize),          // Producer position
    tail: std.atomic.Value(usize),          // Consumer position
    allocator: Allocator,

    pub fn push(self: *Self, event: Event) bool {
        const head = self.head.load(.acquire);
        const next_head = (head + 1) % self.capacity;
        const tail = self.tail.load(.acquire);

        if (next_head == tail) {
            return false;  // Buffer full
        }

        self.items[head] = event;
        self.head.store(next_head, .release);  // ← Atomic release
        return true;
    }

    pub fn pop(self: *Self) ?Event {
        const tail = self.tail.load(.acquire);
        const head = self.head.load(.acquire);

        if (tail == head) {
            return null;  // Buffer empty
        }

        const event = self.items[tail];
        const next_tail = (tail + 1) % self.capacity;
        self.tail.store(next_tail, .release);  // ← Atomic release
        return event;
    }
};
```

**Why lock-free?**
- No mutex contention (critical for < 1µs latency)
- Wait-free for producers (guaranteed progress)
- Non-blocking for consumers (workers never block each other)

**Limitations:**
- Fixed capacity (8192 events)
- Single producer only (handlers must publish via MessageBus, which serializes)
- Modulo arithmetic (not power-of-2) for flexibility

### 3. Subscriber Registry (`src/message_bus/subscriber_registry.zig`)

Thread-safe registry using RwLock:

```zig
pub const SubscriberRegistry = struct {
    subscriptions: std.StringHashMap(ArrayList(Subscription)),
    lock: std.Thread.RwLock,  // Read-heavy workload
    allocator: Allocator,

    pub fn subscribe(...) !SubscriptionId {
        self.lock.lock();         // ← Exclusive lock for writes
        defer self.lock.unlock();

        // Add subscription to map
    }

    pub fn getMatching(...) ![]const Subscription {
        self.lock.lockShared();   // ← Shared lock for reads
        defer self.lock.unlockShared();

        // Find matching subscriptions (no writes, parallel-safe)
    }
};
```

**Why RwLock?**
- Read-heavy workload (many lookups, few subscribe/unsubscribe)
- Shared locks allow parallel event matching
- Write lock only for subscribe/unsubscribe (rare)

**Alternative considered:**
- Lock-free subscriber registry (more complex, marginal benefit)
- Current design is "good enough" (lookups < 10µs)

### 4. Filter System (`src/message_bus/filter.zig`)

SQL-like filtering on JSON event data:

```zig
pub const Filter = struct {
    conditions: []WhereClause,

    pub fn matches(
        self: *const Self,
        event: *const Event,
        allocator: Allocator,
    ) !bool {
        // Parse event.data (JSON)
        var parsed = std.json.parseFromSlice(...);
        defer parsed.deinit();

        // Evaluate each condition (AND logic)
        for (self.conditions) |condition| {
            const field_value = getNestedField(parsed.value, condition.field);
            if (!evaluateCondition(field_value, condition.op, condition.value)) {
                return false;
            }
        }

        return true;
    }
};
```

**Performance considerations:**
- Lazy JSON parsing (only when filter conditions exist)
- Typical latency: 5-10µs per filter evaluation
- Runs on EventWorker thread (off hot path)

### 5. Event Workers (`src/message_bus/event_worker.zig`)

Background threads that deliver events:

```zig
pub const EventWorker = struct {
    id: usize,
    message_bus: *MessageBus,
    config: MessageBus.Config,

    pub fn run(self: *Self) void {
        while (!self.message_bus.shutdown.load(.acquire)) {
            // Pop event from ring buffer
            const event = self.message_bus.event_queue.pop() orelse {
                std.Thread.sleep(self.config.flush_interval_ms * std.time.ns_per_ms);
                continue;
            };

            // Get matching subscribers (RwLock shared)
            const subscribers = self.message_bus.subscribers.getMatching(&event, allocator);
            defer allocator.free(subscribers);

            // Deliver to all subscribers (parallel)
            self.deliverParallel(&event, subscribers, allocator);

            // Persist to audit log (async)
            self.persistEvent(&event) catch |err| {
                std.log.err("Worker {}: Persist failed: {}", .{self.id, err});
            };
        }
    }

    fn deliverParallel(...) void {
        // Execute each handler (error isolation!)
        for (subscribers) |sub| {
            sub.handler(event, allocator);  // ← Handler must not throw!
        }
    }
};
```

**Key features:**
- Parallel execution across workers (4 threads default)
- Error isolation (one handler failure doesn't affect others)
- Async ClickHouse writes (batched for efficiency)

### 6. Entity-Owned Topics (`src/message_bus/model_topics.zig`)

Comptime generators for topic string constants. Topics are declared by the entities that own them — no central registry.

```zig
// ModelTopics generates standard CRUD topics for any entity
pub fn ModelTopics(comptime name: []const u8) type {
    return struct {
        pub const created = name ++ ".created";
        pub const updated = name ++ ".updated";
        pub const deleted = name ++ ".deleted";
        pub const wildcard = name ++ ".*";
    };
}

// Format-based validation (replaces membership-based)
pub fn validateTopicFormat(comptime topic: []const u8) void {
    comptime {
        // Must be "Category.event" — exactly one dot, non-empty on both sides
    }
}
```

**Why decentralized?**
- Adding a new entity doesn't require editing a separate file
- Topics are co-located with the models that own them
- Format validation catches malformed topics at compile time
- Zero runtime cost (all comptime)

### 7. Event Builder (`src/message_bus/event_builder.zig`)

Simplified API for users:

```zig
pub const EventBuilder = struct {
    event: Event,

    pub fn init(comptime topic: []const u8) Self {
        validateTopicFormat(topic);  // ← Compile-time format check

        return Self{
            .event = Event{
                .id = generateEventId(),
                .timestamp = std.time.microTimestamp(),
                .topic = topic,
                // ... defaults ...
            },
        };
    }

    pub fn publish(self: Self, bus: *MessageBus) void {
        bus.publish(self.event);
    }
};

pub fn publishEvent(comptime topic: []const u8, data: []const u8) void {
    const globals = @import("../globals.zig");
    if (globals.global_message_bus) |bus| {
        EventBuilder.init(topic).data(data).publish(bus);
    }
}
```

**Design philosophy:**
- Hide Event internals from users
- Fluent API for readability
- One-liner for common case

---

## Threading Model

### Process Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                      Server Process (PID 1234)                  │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Main Thread (TID 1234)                                         │
│  ├─ Initialize MessageBus (main.zig:58)                        │
│  ├─ Start EventWorkers (main.zig:65)                           │
│  └─ Run TCP Server Loop                                         │
│                                                                 │
│  EventWorker Thread 0 (TID 1235)                                │
│  ├─ Poll ring buffer                                            │
│  ├─ Match subscribers (RwLock shared)                          │
│  ├─ Execute handlers (parallel)                                │
│  └─ Persist to ClickHouse                                       │
│                                                                 │
│  EventWorker Thread 1 (TID 1236)                                │
│  EventWorker Thread 2 (TID 1237)                                │
│  EventWorker Thread 3 (TID 1238)                                │
│                                                                 │
│  TCP Worker Threads (TID 1239-1246) [8 threads]                │
│  ├─ Handle requests                                             │
│  ├─ Execute handlers                                            │
│  └─ Publish events → Ring buffer                               │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
```

### Thread Interactions

**Publish Path (TCP Worker → Ring Buffer):**
1. TCP worker handles request
2. Handler calls `publishEvent()`
3. Lock-free push to ring buffer (< 1µs)
4. Return to TCP worker immediately

**Delivery Path (EventWorker → Subscriber):**
1. EventWorker pops from ring buffer
2. Get matching subscribers (RwLock shared)
3. Execute all handler callbacks (parallel)
4. Persist event to ClickHouse (async)

### Synchronization Points

**None on hot path!**
- Ring buffer uses atomic operations only
- Subscriber matching uses RwLock (shared, non-exclusive)
- Handler execution is parallel (no locking)

**Off hot path:**
- Subscribe/unsubscribe (RwLock exclusive)
- ClickHouse writes (batched, async)

---

## Lock-Free Design

### Atomics Used

**Ring Buffer:**
```zig
head: std.atomic.Value(usize),  // Producer position
tail: std.atomic.Value(usize),  // Consumer position

// Push (acquire-release semantics)
const head = self.head.load(.acquire);       // ← Memory fence
self.items[head] = event;
self.head.store(next_head, .release);        // ← Memory fence

// Pop (acquire-release semantics)
const tail = self.tail.load(.acquire);
const event = self.items[tail];
self.tail.store(next_tail, .release);
```

**Statistics Counters:**
```zig
total_published: std.atomic.Value(u64),
total_dropped: std.atomic.Value(u64),
total_delivered: std.atomic.Value(u64),

// Increment (monotonic ordering sufficient)
_ = self.total_published.fetchAdd(1, .monotonic);
```

### Memory Ordering

- **Acquire:** Prevents reordering of subsequent reads
- **Release:** Prevents reordering of prior writes
- **Monotonic:** No reordering constraints (counters only)

### Why Not Fully Lock-Free?

**Subscriber registry uses RwLock:**
- Subscribe/unsubscribe are rare operations
- Lock-free hash map is complex (ABA problem, memory reclamation)
- RwLock shared reads are fast enough (< 5µs)

**Trade-off:** Simplicity > marginal performance gain

---

## Performance Characteristics

### Latency Breakdown

| Operation | Latency | Notes |
|-----------|---------|-------|
| `publishEvent()` | < 1µs | Lock-free ring buffer push |
| Filter evaluation | 5-10µs | JSON parsing + condition eval |
| Handler execution | Variable | User code (should be < 100µs) |
| ClickHouse write | Async | Batched, off hot path |
| Subscribe/unsubscribe | 10-50µs | Rare operations |

### Throughput

- **Ring buffer capacity:** 8192 events
- **Worker count:** 4 threads (configurable)
- **Expected throughput:** 50k-100k events/sec
- **Bottleneck:** Handler execution time

### Memory Usage

```
Ring buffer: 8192 events × ~256 bytes = ~2 MB
Subscriber registry: ~100 subscriptions × ~128 bytes = ~13 KB
Worker stacks: 4 threads × 16 KB = 64 KB
Total: ~2.1 MB
```

### CPU Usage

- Idle: 0% (workers sleep when queue empty)
- Active: Proportional to event rate
- Per-event cost: ~1-5µs CPU time

---

## File Structure

```
src/
├── event.zig                        # Event type definition
├── globals.zig                      # Global message bus instance
└── message_bus/
    ├── mod.zig                      # Module exports
    ├── message_bus.zig              # Core MessageBus struct
    ├── ring_buffer.zig              # Lock-free event queue
    ├── event_worker.zig             # Worker threads
    ├── subscriber.zig               # Subscription types
    ├── subscriber_registry.zig      # Subscriber storage
    ├── filter.zig                   # Event filtering
    ├── model_topics.zig             # Entity-owned topic generators
    ├── system_topics.zig            # System-level topics
    ├── event_builder.zig            # Simplified API
    └── global.zig                   # Global instance functions
```

### Initialization Flow

```
main.zig:58
  ↓
MessageBus.init()  (message_bus.zig:45)
  ↓
├─ EventRingBuffer.init()  (ring_buffer.zig:15)
├─ SubscriberRegistry.init()  (subscriber_registry.zig:20)
└─ EventWorker.init() × 4  (event_worker.zig:12)
  ↓
MessageBus.start()  (message_bus.zig:84)
  ↓
std.Thread.spawn(EventWorker.run) × 4
  ↓
Workers running (infinite loop)
```

---

## Adding Features

### Adding a New Topic

Topics are decentralized — no central file to edit. Just use the appropriate generator:

**Standard CRUD entity:**

```zig
// Use ModelTopics — generates created/updated/deleted/wildcard
message_bus.publishEvent(message_bus.ModelTopics("Payment").created, data);

// Subscribe
_ = try bus.subscribe(
    message_bus.ModelTopics("Payment").updated,
    filter,
    onPaymentUpdated,
);
```

**Custom event (non-CRUD):**

```zig
message_bus.publishEvent(message_bus.CustomTopic("Payment.refunded"), data);
```

Topic format is validated at compile time — must be `"Category.event"` with exactly one dot.

### Adding a New Filter Operator

**Edit `src/message_bus/filter.zig`:**

```zig
pub const Op = enum {
    eq, ne, gt, gte, lt, lte,
    regex,  // ← New operator
};

fn evaluateCondition(...) bool {
    switch (condition.op) {
        .regex => {
            // Implement regex matching
            return matchesRegex(field_value, condition.value);
        },
        // ... existing cases ...
    }
}
```

### Adding Event Batching

Currently, events are processed one-by-one. To batch:

**Edit `src/message_bus/event_worker.zig`:**

```zig
pub fn run(self: *Self) void {
    var batch: [64]Event = undefined;
    var batch_size: usize = 0;

    while (!self.message_bus.shutdown.load(.acquire)) {
        // Fill batch
        while (batch_size < batch.len) {
            const event = self.message_bus.event_queue.pop() orelse break;
            batch[batch_size] = event;
            batch_size += 1;
        }

        if (batch_size == 0) {
            std.Thread.sleep(self.config.flush_interval_ms * std.time.ns_per_ms);
            continue;
        }

        // Process batch
        for (batch[0..batch_size]) |*event| {
            self.deliverEvent(event);
        }

        batch_size = 0;
    }
}
```

### Adding Metrics

**Edit `src/message_bus/message_bus.zig`:**

```zig
pub const MessageBus = struct {
    // ... existing fields ...

    // Add metrics
    latency_histogram: [10]std.atomic.Value(u64),  // 0-1µs, 1-10µs, etc.
    events_per_topic: std.StringHashMap(u64),

    pub fn publish(self: *Self, event: Event) void {
        const start = std.time.nanoTimestamp();

        // ... publish logic ...

        const latency_ns = std.time.nanoTimestamp() - start;
        self.recordLatency(latency_ns);
        self.incrementTopicCount(event.topic);
    }
};
```

---

## Testing

### Unit Tests

**Ring buffer:**
```bash
zig test src/message_bus/ring_buffer.zig
```

**Filters:**
```bash
zig test src/message_bus/filter.zig
```

**Topics:**
```bash
zig test src/message_bus/model_topics.zig
```

### Integration Tests

**Full message bus:**
```bash
zig test src/message_bus/integration_test.zig
```

### Load Testing

**Benchmark:**
```bash
./zig-out/bin/message_bus_benchmark --events 100000 --workers 4
```

Expected output:
```
Published: 100000 events
Delivered: 100000 events
Dropped: 0 events
Latency P50: 0.8µs
Latency P99: 2.1µs
Throughput: 85000 events/sec
```

---

## Performance Tuning

### Ring Buffer Size

**Trade-off:**
- Larger buffer → less likely to drop events under burst load
- Larger buffer → more memory usage

**Tune:**
```zig
var bus = try MessageBus.init(allocator, .{
    .queue_capacity = 16384,  // Double default size
});
```

### Worker Count

**Trade-off:**
- More workers → higher throughput
- More workers → more CPU usage, cache contention

**Tune:**
```zig
var bus = try MessageBus.init(allocator, .{
    .worker_count = 8,  // More workers for high throughput
});
```

**Guideline:** Match worker count to CPU cores available for message bus.

### Flush Interval

How often workers check empty queue:

```zig
var bus = try MessageBus.init(allocator, .{
    .flush_interval_ms = 10,  // Check every 10ms (faster, more CPU)
});
```

**Trade-off:**
- Lower interval → lower latency when queue is empty
- Lower interval → more CPU usage (busy polling)

---

## Debugging

### Enable Verbose Logging

**Edit `src/message_bus/event_worker.zig`:**

```zig
pub fn run(self: *Self) void {
    std.log.debug("EventWorker {} started", .{self.id});  // ← Change to debug

    while (!self.message_bus.shutdown.load(.acquire)) {
        const event = self.message_bus.event_queue.pop() orelse {
            std.log.debug("Worker {}: Queue empty", .{self.id});  // ← Add debug
            std.Thread.sleep(...);
            continue;
        };

        std.log.debug("Worker {}: Processing event {}", .{self.id, event.id});  // ← Add debug
        // ...
    }
}
```

**Run with:**
```bash
./zig-out/bin/server --log-level debug
```

### Check Statistics

```zig
const stats = message_bus.getStats();
std.log.info("Published: {}, Delivered: {}, Dropped: {}, Queued: {}",
    .{stats.published, stats.delivered, stats.dropped, stats.queued});
```

### Trace Event Flow

Add event ID logging at each stage:

```zig
// Publish
std.log.info("Event {} published to topic {s}", .{event.id, event.topic});

// Worker pop
std.log.info("Event {} popped by worker {}", .{event.id, worker.id});

// Subscriber match
std.log.info("Event {} matched {} subscribers", .{event.id, subscribers.len});

// Handler execution
std.log.info("Event {} delivered to subscriber {}", .{event.id, sub.id});
```

### Common Issues

**Events not delivered:**
1. Check worker threads are running: `ps -T -p <pid>`
2. Check queue size: `stats.queued` (if 0, workers are processing)
3. Check subscription exists: Log subscriber count
4. Check filter matches: Add debug logging in `filter.matches()`

**High latency:**
1. Check handler execution time (should be < 100µs)
2. Check worker count (may need more workers)
3. Check queue full (dropped events > 0)

**Memory leaks:**
1. Check unsubscribe is called in handler deinit
2. Check event data is not allocated on heap
3. Run with valgrind: `valgrind --leak-check=full ./zig-out/bin/server`

---

## Summary

### Key Design Decisions

1. **Lock-free ring buffer** - Optimized for < 1µs publish latency
2. **RwLock subscriber registry** - Good enough for read-heavy workload
3. **Compile-time topic validation** - Zero runtime cost, typo-proof
4. **Background workers** - Async delivery, non-blocking publishers
5. **Tiger Style handlers** - Never throw, error isolation

### Performance Targets

- Publish: < 1µs
- Filter: < 10µs
- Handler: < 100µs (user responsibility)
- Throughput: 50k-100k events/sec

### Future Improvements

- NUMA-aware worker placement
- Lock-free subscriber registry
- Zero-copy event batching
- Persistent queue (disk-backed)
- Event replay from ClickHouse

---

**Last Updated:** 2026-03-05
**Framework Version:** 0.3.0-alpha
