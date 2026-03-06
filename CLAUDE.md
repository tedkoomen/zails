# Claude AI Context - Zerver Framework

This file contains essential context for Claude AI when working on the Zerver framework codebase.

## Project Overview

**Zerver** is a high-performance gRPC Rails-like framework written in Zig, designed to achieve sub-100µs latency while providing Rails-like developer experience.

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
│   ├── zerver.zig                  # CLI tool (generators)
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

### 4. Code Generators

```bash
zerver create model User --table=users          # Generate ORM model
zerver create service UserService               # Generate gRPC service
zerver create migration add_email               # Generate migration
zerver scaffold Post --fields=title:String      # Full CRUD scaffold
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

## Performance Profiling

Before submitting performance-critical code:

1. **Measure latency** - Aim for sub-100µs P50
2. **Check allocations** - Should be zero in hot path
3. **Verify comptime** - Use `@compileLog` to verify comptime evaluation
4. **Benchmark** - Use existing benchmarks in `src/*_benchmark.zig`

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

## Current Status (2026-03-05)

### ✅ Completed (v0.3.0-alpha)

- gRPC protocol integration (proto.zig, grpc_registry.zig, grpc_handler_adapter.zig)
- ClickHouse ORM (query_builder, model, field_types)
- Code generators (model, service, migration, scaffold)
- HTTP client with connection pooling
- Comprehensive test suite (all passing)

### ⏳ In Progress

- Event-driven architecture (message bus for model changes)
- Handler subscriptions (handlers listen to model updates)

### 📋 Roadmap

See [ROADMAP.md](ROADMAP.md) for complete feature roadmap and timeline.

## Quick Reference

### Build & Run

```bash
zig build                              # Build server
zig build run -- --ports 8080          # Run server
zig test src/proto.zig                 # Run tests
```

### Code Generation

```bash
zerver create model User               # Generate model
zerver create service UserService      # Generate gRPC service
zerver create migration add_users      # Generate migration
zerver scaffold Post                   # Full CRUD scaffold
zerver build                           # Regenerate handlers/mod.zig
```

### Debugging

```bash
# Enable verbose logging
./zig-out/bin/server --ports 8080 --log-level debug

# Profile CPU
# TODO: Add profiling commands

# Check memory leaks
# TODO: Add leak detection
```

## Common Gotchas

1. **Always use Tiger Style** - Don't throw in handlers
2. **Comptime vs Runtime** - If it can be comptime, make it comptime
3. **Lock-free patterns** - Use atomic operations, never mutexes in hot path
4. **ClickHouse semantics** - It's analytics-first, not OLTP (no transactions)
5. **MESSAGE_TYPE uniqueness** - Must be unique across all handlers
6. **Stack buffer sizes** - Ensure buffers are large enough (4KB typical)
7. **gRPC over TCP** - Not HTTP/2, custom wire format for performance

## Resources

- **Architecture:** High-performance TCP server with epoll workers
- **Database:** ClickHouse (analytics/OLAP, not OLTP)
- **Protocol:** Custom protobuf over TCP (gRPC-style)
- **Language:** Zig 0.13+ (master branch)

## When to Ask for Help

If you encounter:
- Latency > 150µs in benchmarks
- Heap allocations in handler hot path
- Runtime dispatch instead of comptime
- Test failures in Tiger Style error handling
- ClickHouse query performance issues

**Check ROADMAP.md first** to see if feature is planned or already implemented.

---

**Last Updated:** 2026-03-05
**Framework Version:** 0.3.0-alpha
**Zig Version:** 0.13.0 (master)
