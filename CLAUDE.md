# Claude AI Context - Zails Framework

This file contains essential context for Claude AI when working on the Zails framework codebase.

## Project Overview

**Zails** is a high-performance gRPC Rails-like framework written in Zig, designed to achieve sub-100µs latency while providing Rails-like developer experience.

### Core Principles

1. **Tiger Style** - Errors are values, never exceptions. All error handling uses `result.HandlerResponse` or similar result types.
2. **Zero Allocations** - Lock-free object pools in hot path, stack-allocated where possible
3. **Comptime Everything** - No runtime dispatch, no vtables, all handler routing via inline for loops
4. **Convention-over-configuration** - Auto-discovery of handlers, models, and services
5. **NUMA-aware** - Automatic worker placement across NUMA nodes

### Performance Targets

- **P50 Latency:** 69µs (current) → < 150µs (target with gRPC)
- **Throughput:** 10k+ req/s → 50k+ req/s
- **Success Rate:** 100% (always)

## Architecture

### Request Flow

```
Client Request
    ↓
TCP Socket (epoll)
    ↓
Lock-free Worker Pool (NUMA-aware)
    ↓
Handler Registry (comptime dispatch)
    ↓
Handler.handle() [Tiger Style - returns HandlerResponse]
    ↓
Response Buffer (pre-allocated, no heap)
    ↓
TCP Socket
    ↓
Client Response
```

### Directory Structure

```
/root/zig_server/
├── src/
│   ├── main.zig                    # Entry point
│   ├── proto.zig                   # Protobuf encoding/decoding + gRPC types
│   ├── grpc_registry.zig           # Comptime service routing
│   ├── grpc_handler_adapter.zig    # gRPC handler wrapper
│   ├── handler_registry.zig        # Comptime handler dispatch
│   ├── result.zig                  # Tiger Style error types
│   ├── pool_lockfree.zig           # Lock-free object pool
│   ├── server_framework.zig        # Core server logic
│   ├── clickhouse_client.zig       # ClickHouse HTTP client
│   ├── async_clickhouse.zig        # Async ClickHouse writer
│   ├── zails.zig                  # CLI tool (generators)
│   └── orm/
│       ├── mod.zig                 # ORM exports
│       ├── query_builder.zig      # SQL query builder
│       ├── model.zig               # ActiveRecord-like models
│       └── field_types.zig         # ClickHouse type mappings
├── handlers/
│   ├── mod.zig                     # Auto-generated handler registry
│   ├── echo_handler.zig            # Example handler
│   └── *_handler.zig               # Convention-based handlers
├── models/                         # ORM models (auto-generated)
├── migrations/                     # Database migrations
├── templates/                      # Code generation templates
└── build.zig                       # Build configuration
```

## Code Style Guide

### Tiger Style Error Handling

**NEVER use try/catch in hot path.** Always return `result.HandlerResponse` or similar result types.

```zig
// ✅ CORRECT - Tiger Style
pub fn handle(
    context: *Context,
    request_data: []const u8,
    response_buffer: []u8,
    allocator: Allocator,
) result.HandlerResponse {
    // Decode (returns Result, not error)
    const req = proto.decodeRequest(allocator, request_data) catch {
        return result.HandlerResponse.err(.malformed_message);
    };

    // Process and return
    return result.HandlerResponse.ok(response_data);
}

// ❌ WRONG - throws exceptions
pub fn handle(...) ![]const u8 {
    const req = try proto.decodeRequest(...);  // DON'T do this in handlers
    return response_data;
}
```

### Comptime Dispatch

**Always use comptime for routing.** No hash maps, no function pointers.

```zig
// ✅ CORRECT - Comptime dispatch
pub fn route(service: []const u8, method: []const u8) ?u8 {
    inline for (services) |svc| {
        if (std.mem.eql(u8, service, svc.service_name) and
            std.mem.eql(u8, method, svc.method_name))
        {
            return svc.message_type;
        }
    }
    return null;
}

// ❌ WRONG - Runtime lookup
pub fn route(service: []const u8, method: []const u8) ?u8 {
    return service_map.get(service); // DON'T use hash maps
}
```

### Stack Allocation

**Avoid heap allocations in hot path.** Use stack buffers and pre-allocated pools.

```zig
// ✅ CORRECT - Stack allocated
var buffer: [4096]u8 = undefined;
const sql = try qb.buildSQL(&buffer);

// ❌ WRONG - Heap allocation
const buffer = try allocator.alloc(u8, 4096); // Avoid in hot path
defer allocator.free(buffer);
```

## Key Components

### 1. Handler System

Handlers are auto-discovered from the `handlers/` directory. Each handler must export:

```zig
pub const MESSAGE_TYPE: u8 = X;  // Unique identifier

pub const Context = struct {
    // Handler state
    pub fn init() Context { ... }
    pub fn deinit(self: *Context) void { ... }
};

pub fn handle(
    context: *Context,
    request_data: []const u8,
    response_buffer: []u8,
    allocator: Allocator,
) result.HandlerResponse {
    // Handler logic
    return result.HandlerResponse.ok(response);
}
```

### 2. gRPC Integration

gRPC is implemented **over TCP** (not HTTP/2) to maintain sub-100µs latency:

- `proto.GrpcRequest` / `proto.GrpcResponse` - gRPC message wrappers
- `grpc_registry.GrpcServiceRegistry` - Comptime service.method → MESSAGE_TYPE routing
- `grpc_handler_adapter.GrpcHandlerAdapter` - Adapts handlers to gRPC interface

Wire format: `[TYPE=250][length][GrpcRequest protobuf]`

### 3. ORM System

ActiveRecord-like ORM for ClickHouse:

```zig
// Define model
const User = orm.Model("users", .{
    .id = orm.FieldDef{ .type = .UInt64, .primary_key = true },
    .name = orm.FieldDef{ .type = .String },
    .email = orm.FieldDef{ .type = .String },
    .status = orm.FieldDef{ .type = .String, .low_cardinality = true },
});

// Query
const active_users = User
    .where("status", .eq, "active")
    .orderBy("created_at", .desc)
    .limit(100)
    .execute(allocator);
```

Query builders are **stack-allocated** and generate ClickHouse-optimized SQL.

### 4. Event System & Message Bus

The message bus provides Kafka-like pub/sub for reactive event-driven architecture. Events flow through a lock-free ring buffer to background worker threads that deliver to matching subscribers.

#### Event Flow

```
Handler / Model Change
    ↓
EventBuilder (fluent API, comptime topic validation)
    ↓
Event struct (stack-allocated, zero heap)
    ↓
MessageBus.publish() → Lock-free Ring Buffer
    ↓
EventWorker threads (background, CPU-pinned)
    ↓
SubscriberRegistry.getMatching()
  ├─ topic match (string compare, no alloc)
  ├─ filter.matches() (typed field compare, no alloc)
  └─ result slice (heap-allocated by getMatching — caller frees)
    ↓
Handler callbacks (parallel delivery)
```

**Allocation boundary:** `filter.matches()` is zero-allocation. `getMatching()` still heap-allocates the returned `[]Subscription` slice (caller must free). This is outside the filter hot path but is a known allocation point in the delivery pipeline.

#### Event Struct (`src/event.zig`)

Events carry both a raw `data` payload (for handler consumption) and up to 8 typed field slots (for zero-allocation filtering):

```zig
pub const Event = struct {
    id: u128,                    // Random UUID
    timestamp: i64,              // Microsecond Unix timestamp
    event_type: EventType,       // model_created/updated/deleted/custom
    topic: []const u8,           // "Trade.created", "Portfolio.updated"
    model_type: []const u8,      // "Trade", "Portfolio"
    model_id: u64,
    data: []const u8,            // Raw payload (format-agnostic: protobuf, raw bytes, etc.)

    // Typed fields for allocation-free filtering
    fields: [MAX_EVENT_FIELDS]Field,  // 8 slots, stack-allocated
    field_count: u8,
};
```

#### Typed Fields — Zero-Allocation Filtering

Every `Event` has a fixed-size array of `Field` slots. Each field is a named, typed value stored entirely on the stack — no heap, no parsing, no allocator. Filtering never touches `event.data`:

```zig
// Types (all stack-allocated, fixed-size)
pub const FixedString = struct { buf: [64]u8, len: u8 };  // No heap
pub const FieldValue = union(enum) { none, int: i64, uint: u64, float: f64, string: FixedString, boolean: bool };
pub const Field = struct { name: [32]u8, name_len: u8, value: FieldValue };

pub const MAX_EVENT_FIELDS = 8;
```

Setting and reading fields:

```zig
var event = Event{ ... };
event.setField("symbol", .{ .string = FixedString.init("AAPL") });
event.setField("price", .{ .int = 15000 });
event.setField("active", .{ .boolean = true });

// Reading
const price = event.getField("price").?.int;  // 15000
```

All fields default to empty, so existing Event struct literals compile unchanged.

#### Filters (`src/message_bus/filter.zig`)

Filters match against typed event fields with **zero allocation**. `filter.matches()` takes no allocator — it's a pure value comparison:

```zig
const filter = Filter{
    .conditions = &.{
        .{ .field = "symbol", .op = .eq, .value = "AAPL" },
        .{ .field = "price", .op = .gt, .value = "1000" },
    },
};

// No allocator, no error, no heap — returns bool directly
const matched = filter.matches(&event);
```

Supported operators: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `like` (substring), `in`, `not_in`. Conditions use AND logic — all must match.

The `WhereClause.value` field is always a string representation. The filter compares it against the typed `FieldValue` by parsing the expected string to the matching type (e.g., `parseInt` for `.int` fields).

#### EventBuilder (`src/message_bus/event_builder.zig`)

Fluent API with comptime topic validation and typed field setters:

```zig
const event = EventBuilder.init("Trade.created")  // comptime topic validation
    .modelType("Trade")
    .modelId(42)
    .stringField("symbol", "AAPL")
    .intField("price", 15000)
    .floatField("ratio", 1.5)
    .boolField("active", true)
    .data(raw_payload)          // optional raw payload (format-agnostic)
    .build();
```

#### Subscribing with Filters

```zig
const filter = Filter{
    .conditions = &.{
        .{ .field = "price", .op = .gt, .value = "1000" },
    },
};

const sub_id = try bus.subscribe("Trade.created", filter, myHandler);
defer bus.unsubscribe(sub_id);
```

Wildcard topics are supported: `"Trade.*"` matches `"Trade.created"`, `"Trade.updated"`, etc.

#### Key Files

| File | Purpose | Allocates? |
|------|---------|------------|
| `src/event.zig` | Event struct, FieldValue, Field, FixedString, typed field helpers | No (stack-only for fields; `initOwned`/`deserialize` allocate for payload copies) |
| `src/message_bus/filter.zig` | Filter matching against typed fields | **No** — pure value comparison, no allocator |
| `src/message_bus/event_builder.zig` | Fluent event construction with typed field setters | No (stack-only) |
| `src/message_bus/message_bus.zig` | Core bus: publish, subscribe, ring buffer, workers | Yes (init, subscribe) |
| `src/message_bus/lockfree_subscriber_registry.zig` | Lock-free subscriber storage (read-optimized) | Yes (`getMatching` allocates result slice) |
| `src/message_bus/subscriber_registry.zig` | Legacy RwLock-based subscriber storage | Yes (`getMatching` allocates result slice) |
| `src/message_bus/mod.zig` | Public API exports | No |

### 5. Code Generators

```bash
zails create model User --table=users          # Generate ORM model
zails create service UserService               # Generate gRPC service
zails create migration add_email               # Generate migration
zails scaffold Post --fields=title:String      # Full CRUD scaffold
```

Generators auto-assign MESSAGE_TYPE by scanning existing handlers.

## Important Constraints

### Memory Management

1. **No allocations in hot path** - Use object pools and stack buffers
2. **Pre-allocate everything** - Response buffers, connection pools
3. **Lock-free data structures** - Atomic operations only (see `pool_lockfree.zig`)

### Error Handling

1. **Never throw in handlers** - Always return `HandlerResponse`
2. **All errors are values** - Use `result.ServerError` enum
3. **No panics** - All failures must be graceful

### Type Safety

1. **Comptime validation** - All handler modules validated at compile time
2. **No dynamic dispatch** - Everything resolved at compile time
3. **Type-safe queries** - Query builders parameterized by model type

## Testing Requirements

All new code must include tests:

```zig
test "descriptive test name" {
    const allocator = std.testing.allocator;

    // Setup
    var thing = Thing.init(allocator);
    defer thing.deinit();

    // Test
    const result = thing.doSomething();

    // Verify
    try std.testing.expectEqual(expected, result);
}
```

Run tests with:
```bash
zig test src/module.zig
```

## Performance Profiling & Benchmarks

Before submitting performance-critical code:

1. **Measure latency** - Aim for sub-100µs P50
2. **Check allocations** - Should be zero in hot path
3. **Verify comptime** - Use `@compileLog` to verify comptime evaluation
4. **Benchmark** - Use the benchmark tools below

### Message Bus Benchmark (`src/message_bus_benchmark.zig`)

Build and run:

```bash
zig build message-bus-bench -Doptimize=ReleaseFast
./zig-out/bin/message_bus_benchmark --mode <mode> [options]
```

**Test modes:**

| Mode | What it measures |
|------|------------------|
| `latency` | Publish + delivery latency (P50/P90/P99), empty filters |
| `throughput` | Max sustained events/sec, single subscriber |
| `stress` | High concurrency, many subscribers, multiple topics |
| `filter` | End-to-end with typed field filters (4 fields, 2 conditions per subscriber) |
| `filter-micro` | Isolated `filter.matches()` cost (no bus, no threads, tight loop) |

**Options:**

```bash
--events N        # Events to publish (default: 100000)
--workers N       # EventWorker threads (default: 4)
--subscribers N   # Number of subscribers (default: 10)
--duration N      # Duration in seconds for timed tests (default: 10)
```

**Examples:**

```bash
# Filter microbenchmark — measure raw filter.matches() nanoseconds/op
./zig-out/bin/message_bus_benchmark --mode filter-micro --events 10000000

# Filter end-to-end — measure delivery with typed field filters
./zig-out/bin/message_bus_benchmark --mode filter --events 100000 --subscribers 10

# Throughput — max events/sec
./zig-out/bin/message_bus_benchmark --mode throughput --duration 5
```

### Current Performance Numbers (ReleaseFast)

**filter.matches() microbenchmark** (10M iterations):

| Scenario | ns/op |
|----------|-------|
| Empty filter (0 conditions) | 0 ns |
| Single int condition | 15 ns |
| Single string condition | 10 ns |
| Two conditions (AND) | 21 ns |
| Missing field (early exit) | 3 ns |
| Max fields (8 fields, 4 conditions) | 58 ns |

**End-to-end publish/delivery:**

| Metric | Value |
|--------|-------|
| Publish P50 | 0.04 µs |
| Publish P99 | ~1.5 µs |
| Publish throughput | ~46k events/sec (10 subscribers) |
| Throughput (1 subscriber) | ~600k events/sec |

### Heartbeat Benchmark (`src/heartbeat_benchmark.zig`)

```bash
zig build heartbeat-bench -Doptimize=ReleaseFast
./zig-out/bin/heartbeat_benchmark
```

## Common Patterns

### 1. Handler Pattern

```zig
pub const MyHandler = struct {
    pub const MESSAGE_TYPE: u8 = 42;

    pub const Context = struct {
        counter: std.atomic.Value(u64),

        pub fn init() Context {
            return .{ .counter = std.atomic.Value(u64).init(0) };
        }

        pub fn deinit(self: *Context) void {
            _ = self;
        }
    };

    pub fn handle(
        context: *Context,
        request_data: []const u8,
        response_buffer: []u8,
        allocator: Allocator,
    ) result.HandlerResponse {
        _ = context.counter.fetchAdd(1, .monotonic);

        // Tiger Style error handling
        const req = proto.decodeRequest(allocator, request_data) catch {
            return result.HandlerResponse.err(.malformed_message);
        };
        defer req.deinit(allocator);

        // Process...

        return result.HandlerResponse.ok(response_data);
    }
};
```

### 2. ORM Model Pattern

```zig
pub const MyModel = orm.Model("my_table", .{
    .id = orm.FieldDef{ .type = .UInt64, .primary_key = true },
    .created_at = orm.FieldDef{ .type = .DateTime64 },
    .status = orm.FieldDef{ .type = .String, .low_cardinality = true },
});

// Custom query method
pub fn recentActive(allocator: Allocator) ![]MyModel {
    return MyModel
        .where("status", .eq, "active")
        .orderBy("created_at", .desc)
        .limit(100)
        .execute(allocator);
}
```

### 3. gRPC Service Pattern

```zig
pub const UserService_GetUser_Handler = struct {
    pub const MESSAGE_TYPE: u8 = 10;

    pub fn handle(...) result.HandlerResponse {
        // Decode gRPC request
        const grpc_req = proto.decodeGrpcRequest(allocator, request_data) catch {
            return result.HandlerResponse.err(.malformed_message);
        };
        defer grpc_req.deinit(allocator);

        // Query database using ORM
        const user = User.find(allocator, user_id) catch {
            return result.HandlerResponse.err(.handler_failed);
        };

        // Encode gRPC response
        const grpc_resp = proto.GrpcResponse{
            .request_id = grpc_req.base.request_id,
            .status_code = .ok,
            .payload = user_data,
        };

        const encoded = proto.encodeGrpcResponse(&grpc_resp, response_buffer) catch {
            return result.HandlerResponse.err(.handler_failed);
        };

        return result.HandlerResponse.ok(encoded);
    }
};
```

### 4. Event Publishing Pattern

```zig
// From a handler or model callback — publish a filtered event
const message_bus = @import("message_bus/mod.zig");
const FixedString = message_bus.FixedString;

// Option A: EventBuilder (fluent, comptime topic validation)
message_bus.EventBuilder.init("Trade.created")
    .modelType("Trade")
    .modelId(trade_id)
    .stringField("symbol", symbol)
    .intField("price", price)
    .data(serialized_payload)
    .publish(bus);

// Option B: Direct Event struct with setField
var event = message_bus.Event{
    .id = message_bus.generateEventId(),
    .timestamp = std.time.microTimestamp(),
    .event_type = .model_created,
    .topic = "Trade.created",
    .model_type = "Trade",
    .model_id = trade_id,
    .data = serialized_payload,
};
event.setField("symbol", .{ .string = FixedString.init(symbol) });
event.setField("price", .{ .int = price });
bus.publish(event);
```

### 5. Event Subscription Pattern

```zig
// Subscribe to high-value AAPL trades only
const filter = message_bus.Filter{
    .conditions = &.{
        .{ .field = "symbol", .op = .eq, .value = "AAPL" },
        .{ .field = "price", .op = .gt, .value = "10000" },
    },
};

const sub_id = try bus.subscribe("Trade.created", filter, handleHighValueTrade);

fn handleHighValueTrade(event: *const message_bus.Event, allocator: Allocator) void {
    // event.data has the raw payload (format-agnostic bytes, not parsed by filters)
    // event.getField("price").?.int has the typed price
    // filter.matches() used zero allocations — pure typed value comparison
    // NOTE: getMatching() allocated the subscriber result slice (freed by worker)
}
```

## Current Status (2026-03-05)

### ✅ Completed (v0.3.0-alpha)

- gRPC protocol integration (proto.zig, grpc_registry.zig, grpc_handler_adapter.zig)
- ClickHouse ORM (query_builder, model, field_types)
- Code generators (model, service, migration, scaffold)
- HTTP client with connection pooling
- Event-driven message bus with zero-allocation filtering (event.zig, message_bus/)
- Comprehensive test suite (all passing)

### ⏳ In Progress

- Handler subscriptions (handlers listen to model updates)

### 📋 Roadmap

See [ROADMAP.md](ROADMAP.md) for complete feature roadmap and timeline.

## Quick Reference

### Install & New Project

```bash
# Install standalone CLI (no source repo needed)
curl -fsSL https://raw.githubusercontent.com/ted-koomen/zails/main/install.sh | sh

# Create and build a new project
zails init my-server
cd my-server
zails build
./zig-out/bin/server --ports 8080
```

### Build from Source (contributors)

```bash
zig build                              # Build server + CLI
zig build run -- --ports 8080          # Run server
zig build test                         # Run tests
```

### CLI Commands

```bash
zails init <name>                      # Create a new project
zails build                            # Regenerate handlers/mod.zig and compile
zails create handler <name>            # Generate a handler
zails create model User --table=users  # Generate ORM model
zails create service UserService       # Generate gRPC service
zails create migration add_users       # Generate migration
zails scaffold Post                    # Full CRUD scaffold (model + migration + service)
zails create config                    # Generate config/ directory
zails help                             # Show help
```

### Debugging & Profiling

```bash
# Enable verbose logging
./zig-out/bin/server --ports 8080 --log-level debug

# Message bus benchmarks (build with ReleaseFast for accurate numbers)
zig build message-bus-bench -Doptimize=ReleaseFast
./zig-out/bin/message_bus_benchmark --mode filter-micro --events 10000000
./zig-out/bin/message_bus_benchmark --mode filter --events 100000
./zig-out/bin/message_bus_benchmark --mode latency --events 50000
./zig-out/bin/message_bus_benchmark --mode throughput --duration 5

# Heartbeat benchmark
zig build heartbeat-bench -Doptimize=ReleaseFast
./zig-out/bin/heartbeat_benchmark
```

## Common Gotchas

1. **Always use Tiger Style** - Don't throw in handlers
2. **Comptime vs Runtime** - If it can be comptime, make it comptime
3. **Lock-free patterns** - Use atomic operations, never mutexes in hot path
4. **ClickHouse semantics** - It's analytics-first, not OLTP (no transactions)
5. **MESSAGE_TYPE uniqueness** - Must be unique across all handlers
6. **Stack buffer sizes** - Ensure buffers are large enough (4KB typical)
7. **gRPC over TCP** - Not HTTP/2, custom wire format for performance
8. **Event fields vs data** - `event.data` is a raw byte payload (format-agnostic — protobuf, raw bytes, anything); `event.fields` are typed slots for filtering. Filters never touch `data`. They are orthogonal — set both when publishing filterable events
9. **Field size limits** - Field names max 32 bytes, string values max 64 bytes, max 8 fields per event. These are stack-allocated fixed buffers, not heap
10. **getMatching() allocates** - `filter.matches()` is zero-allocation, but `getMatching()` in both registries heap-allocates the returned `[]Subscription` slice. Caller must free

## Resources

- **Architecture:** High-performance TCP server with epoll workers
- **Database:** ClickHouse (analytics/OLAP, not OLTP)
- **Protocol:** Custom protobuf over TCP (gRPC-style)
- **Language:** Zig 0.15.2+
- **Distribution:** Standalone binary (framework files embedded via `@embedFile`)

## When to Ask for Help

If you encounter:
- Latency > 150µs in benchmarks
- Heap allocations in handler hot path
- Runtime dispatch instead of comptime
- Test failures in Tiger Style error handling
- ClickHouse query performance issues

**Check ROADMAP.md first** to see if feature is planned or already implemented.

---

**Last Updated:** 2026-03-06
**Framework Version:** 0.3.0-alpha
**Zig Version:** 0.15.2
