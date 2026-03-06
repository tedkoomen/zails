# Contributing to Zerver

This guide covers development, testing, and contribution guidelines for Zerver.

## Table of Contents

- [Philosophy](#philosophy)
- [Getting Started](#getting-started)
- [Project Structure](#project-structure)
- [Development Workflow](#development-workflow)
- [Testing](#testing)
- [Performance Benchmarking](#performance-benchmarking)
- [Code Style](#code-style)
- [Architecture Principles](#architecture-principles)

## Philosophy

**One Way To Do It** - Convention over configuration

Zerver is built on these core principles:

1. **Convention over Configuration** - Rails-like approach to reduce boilerplate
2. **Comptime Everything** - Zero runtime polymorphism
3. **Lock-Free Everything** - No mutexes, no condition variables
4. **Zero Allocations** - Pre-allocated pools for predictable performance
5. **NUMA-Aware** - Automatic CPU pinning for lower latency

## Getting Started

### Prerequisites

- Zig 0.15.2 or later
- Linux (for NUMA support)
- OpenSSL dev libraries (optional)
- Docker (for ClickHouse integration testing)
- Git

### Build from Source

```bash
# Clone repository
git clone https://github.com/yourusername/zerver.git
cd zerver

# Build all targets
zig build

# Run tests
zig build test

# Build and run server
zig build run -- --ports 8080
```

## Project Structure

```
zerver/
├── src/
│   ├── main.zig                    # Entry point
│   ├── config.zig                  # CLI argument parsing
│   ├── config_system.zig           # Advanced config (ZerverConfig)
│   ├── handler_registry.zig        # Comptime handler dispatch
│   ├── epoll_threadpool.zig        # Epoll-based worker pool
│   ├── numa.zig                    # NUMA topology detection
│   ├── pool_lockfree.zig           # Lock-free object pools
│   ├── proto.zig                   # Protobuf encoding/decoding + gRPC
│   ├── grpc_registry.zig           # Comptime gRPC service routing
│   ├── grpc_handler_adapter.zig    # gRPC handler wrapper
│   ├── result.zig                  # Tiger Style error types
│   ├── event.zig                   # Event struct (owned data lifecycle)
│   ├── globals.zig                 # Global state pointers
│   ├── signals.zig                 # Signal handling
│   ├── metrics.zig                 # Metrics registry
│   ├── clickhouse_client.zig       # ClickHouse HTTP client
│   ├── async_clickhouse.zig        # Async ClickHouse writer
│   ├── zerver.zig                  # CLI tool (generators)
│   │
│   ├── message_bus/                # Event-driven pub/sub system
│   │   ├── mod.zig                 # Public exports
│   │   ├── message_bus.zig         # Core bus (queue + workers)
│   │   ├── ring_buffer.zig         # Lock-free event ring buffer
│   │   ├── event_worker.zig        # Background event delivery
│   │   ├── subscriber.zig          # Subscriber types
│   │   ├── filter.zig              # Event filtering
│   │   ├── lockfree_subscriber_registry.zig
│   │   ├── model_topics.zig         # Entity-owned topic generators
│   │   └── system_topics.zig        # System-level topics
│   │
│   ├── udp/                        # UDP feed ingestion
│   │   ├── mod.zig                 # Public exports
│   │   ├── binary_protocol.zig     # Comptime protocol generator
│   │   ├── udp_listener.zig        # Socket binding, recv loop
│   │   ├── feed_manager.zig        # Multi-feed thread lifecycle
│   │   ├── feed_config.zig         # Feed configuration types
│   │   └── sequence_tracker.zig    # Gap/duplicate detection
│   │
│   ├── protocols/                  # Protocol definitions
│   │   └── example_itch.zig        # Reference ITCH protocol
│   │
│   └── orm/                        # ClickHouse ORM
│       ├── mod.zig                 # ORM exports
│       ├── query_builder.zig       # SQL query builder
│       ├── model.zig               # ActiveRecord-like models
│       └── field_types.zig         # ClickHouse type mappings
│
├── handlers/                       # Handler implementations
│   ├── mod.zig                     # Handler registry
│   ├── echo_handler.zig            # Echo handler
│   ├── ping_handler.zig            # Ping handler
│   └── event_demo_handler.zig      # Message bus demo
│
├── docs/                           # Extended documentation
│   ├── README.md
│   └── message_bus/                # Message bus guides
│
├── build.zig                       # Build configuration
├── USAGE.md                        # User guide
├── ROADMAP.md                      # Feature roadmap
└── CONTRIBUTING.md                 # This file
```

## Development Workflow

### 1. Create a Feature Branch

```bash
git checkout -b feature/your-feature-name
```

### 2. Make Changes

#### Adding a New Handler

1. Create `handlers/your_handler.zig`:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MESSAGE_TYPE: u8 = 99; // Unique ID

pub const Context = struct {
    // Your state here
    pub fn init() Context {
        return .{};
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
) ![]const u8 {
    // Your logic here
    return response_buffer[0..0];
}
```

2. Register in `handlers/mod.zig`:

```zig
pub const your_handler = @import("your_handler.zig");

pub const handler_modules = .{
    echo_handler,
    ping_handler,
    your_handler,  // Add here
};
```

3. Add tests in your handler file:

```zig
test "your_handler basic functionality" {
    var ctx = Context.init();
    defer ctx.deinit();

    var response_buffer: [4096]u8 = undefined;
    const result = try handle(
        &ctx,
        "test input",
        &response_buffer,
        std.testing.allocator,
    );

    try std.testing.expect(result.len > 0);
}
```

#### Adding a Binary Protocol Definition

1. Create `src/protocols/your_protocol.zig`:

```zig
const udp = @import("../udp/mod.zig");

pub const PROTOCOL_ID: u8 = 3; // Must be unique across all protocols

pub const TOPIC = "Feed.your_protocol";

pub const YourMessage = udp.BinaryProtocol("YourProto_Message", .{
    .msg_type  = .{ .type = .u8,    .offset = 0 },
    .sequence  = .{ .type = .u32,   .offset = 1 },
    .payload   = .{ .type = .u64,   .offset = 5 },
    .symbol    = .{ .type = .ascii, .offset = 13, .size = 8 },
});
```

2. Register the protocol tuple in `src/main.zig`:

```zig
const your_proto = @import("protocols/your_protocol.zig");

const FeedProtocols = .{
    // ... existing protocols ...
    .{ .PROTOCOL_ID = your_proto.PROTOCOL_ID, .Parser = your_proto.YourMessage, .TOPIC = your_proto.TOPIC },
};
```

3. Declare the topic in your protocol file (topics are entity-owned, no central registry):

```zig
pub const TOPIC = "Feed.your_protocol";  // Already done in the protocol file
```

4. Add tests in your protocol file:

```zig
test "YourMessage parse and JSON round-trip" {
    var buf: [21]u8 = undefined;
    buf[0] = 0x41; // msg_type
    std.mem.writeInt(u32, buf[1..5], 42, .big);
    // ... fill remaining fields ...

    const result = YourMessage.parse(&buf);
    try std.testing.expect(result.isOk());
    try std.testing.expectEqual(@as(u32, 42), result.msg.sequence);
}
```

#### Adding a Message Bus Subscriber

Handlers can subscribe to events from feeds or other handlers:

```zig
// In your handler's postInit:
pub fn postInit(allocator: Allocator) !void {
    const bus = globals.global_message_bus orelse return;
    _ = try bus.subscribe("Feed.itch", .{ .conditions = &.{} }, onFeedEvent);
}

fn onFeedEvent(event: *const Event) void {
    // event.data contains the JSON payload
    // event.topic is "Feed.itch"
    // event.model_type is "ITCH_AddOrder"
}
```

#### Modifying Core Framework

1. Make changes in `src/`
2. Run tests: `zig build test`
3. Run load tests to verify performance hasn't regressed
4. Update documentation if changing public APIs

### 3. Test Your Changes

```bash
# Run unit tests
zig build test

# Run specific test
zig test src/your_file.zig

# Start server for manual testing
./zig-out/bin/server --ports 8080

# Run load tests
./zig-out/bin/test_harness 8080 50 1000
```

### 4. Submit Pull Request

1. Commit your changes with clear messages:
```bash
git add .
git commit -m "Add feature: brief description

- Detailed point 1
- Detailed point 2
"
```

2. Push to your fork:
```bash
git push origin feature/your-feature-name
```

3. Create PR with:
   - Clear description of changes
   - Test results (load test output)
   - Performance impact (if applicable)

## Testing

### Unit Tests

```bash
# Run all tests
zig build test

# Run tests for specific file
zig test src/pool_lockfree.zig
zig test src/handler_registry.zig
```

### Integration Tests

```bash
# Start server
./zig-out/bin/server --ports 8080 &
SERVER_PID=$!

# Run test harness
./zig-out/bin/test_harness 8080 10 1000

# Cleanup
kill $SERVER_PID
```

### Load Tests

The test harness supports multiple modes:

#### Request-Count Mode (Original)
```bash
# 50 clients, 10K requests each
./zig-out/bin/test_harness 8080 50 10000
```

#### Duration-Based Mode
```bash
# Run for 5 minutes with progress reporting every 30s
./zig-out/bin/test_harness 8080 100 --duration=300 --progress=30
```

#### Hybrid Mode
```bash
# Stop after 10 minutes OR 1M total requests (whichever first)
./zig-out/bin/test_harness 8080 50 \
    --duration=600 \
    --requests=20000 \
    --hybrid \
    --progress=60
```

### ClickHouse Integration Tests

```bash
# Start ClickHouse
./scripts/start-clickhouse.sh

# Start server with ClickHouse enabled
./scripts/start-server.sh --ports 8080

# Run load test
./zig-out/bin/test_harness 8080 50 10000

# Query metrics
curl 'http://localhost:8123/?query=SELECT+count()+FROM+zerver.zerver_request_metrics'

# Cleanup
docker stop zerver-clickhouse
```

## Performance Benchmarking

### Baseline Performance Test

Before making changes:

```bash
# Start server
./zig-out/bin/server --ports 8080 &

# Run baseline test
./zig-out/bin/test_harness 8080 50 100000 > baseline.txt

# Check results
cat baseline.txt
```

After making changes:

```bash
# Rebuild
zig build

# Run same test
./zig-out/bin/test_harness 8080 50 100000 > after-changes.txt

# Compare
diff baseline.txt after-changes.txt
```

### Key Metrics to Monitor

- **Throughput**: Should be >100K req/s on 4-core machine
- **P50 Latency**: Should be <100µs
- **P99 Latency**: Should be <1ms
- **Success Rate**: Should be >99.9%

### Long-Running Stability Test

```bash
# Run for 1 hour to check for memory leaks
./zig-out/bin/test_harness 8080 100 \
    --duration=3600 \
    --progress=300

# Monitor with htop or top in another terminal
# Memory should remain stable
```

## Code Style

### General Guidelines

1. **Follow Zig conventions** - Use `snake_case` for variables/functions, `PascalCase` for types
2. **No dynamic allocation in hot path** - Use object pools
3. **No mutexes in hot path** - Use atomics and lock-free structures
4. **Comptime everything possible** - Leverage compile-time computation
5. **Explicit error handling** - Use `try` and handle errors properly

### Example: Good vs Bad

**Good:**
```zig
pub fn handle(
    context: *Context,
    request_data: []const u8,
    response_buffer: []u8,
    allocator: Allocator,
) ![]const u8 {
    // Use pre-allocated response_buffer
    std.mem.writeInt(u64, response_buffer[0..8], value, .big);
    return response_buffer[0..8];
}
```

**Bad:**
```zig
pub fn handle(...) ![]const u8 {
    // DON'T allocate in hot path!
    const response = try allocator.alloc(u8, 8);
    return response;
}
```

### Atomics Best Practices

**Good:**
```zig
pub const Context = struct {
    counter: std.atomic.Value(u64),

    pub fn increment(self: *Context) void {
        _ = self.counter.fetchAdd(1, .monotonic);
    }
};
```

**Bad:**
```zig
pub const Context = struct {
    counter: u64,
    mutex: std.Thread.Mutex,  // Don't use mutexes!

    pub fn increment(self: *Context) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.counter += 1;
    }
};
```

## Architecture Principles

### 1. Convention Over Configuration

Handlers are auto-discovered from `handlers/` folder. No manual registration needed.

**Why?** Reduces boilerplate and enforces consistent structure.

### 2. Comptime Polymorphism

All handler dispatch happens at compile time via `inline for`:

```zig
pub fn dispatch(msg_type: u8, ...) ![]const u8 {
    inline for (handler_modules) |module| {
        if (msg_type == module.MESSAGE_TYPE) {
            return module.handle(...);  // Direct call, can inline
        }
    }
    return error.UnknownMessageType;
}
```

**Why?** Zero runtime overhead, better inlining, simpler code.

### 3. Lock-Free Concurrency

Use atomic operations instead of mutexes:

- Work queue: Lock-free ring buffer with CAS
- Threadpool: Work-stealing with atomic counters
- Object pools: Per-worker pools (no sharing)

**Why?** Predictable latency, no syscalls, better scalability.

### 4. Zero-Allocation Hot Path

Pre-allocate everything:

- Connection buffers: From object pool
- Request/response buffers: From pool
- Worker context: Allocated once at startup

**Why?** Predictable performance, no GC pauses, better cache locality.

### 5. NUMA Awareness

Workers and listeners are pinned to NUMA nodes:

```zig
// Pin worker to NUMA node
try numa.setCPUAffinity(worker_id);
```

**Why?** Lower memory access latency (local > remote), better cache utilization.

### 6. Event-Driven Architecture

The message bus decouples producers from consumers:

- Lock-free ring buffer for the event queue (no mutex on publish)
- Background event workers drain the queue and deliver to subscribers
- Topic-based routing with wildcard support (`Feed.*`)
- Events own their data (`Event.initOwned` copies payload)

**Why?** Handlers don't need to know about each other. Feed data flows to any subscriber without coupling.

### 7. Comptime Protocol Generation

Binary protocols are defined as field/offset/type tuples:

```zig
const AddOrder = BinaryProtocol("ITCH_AddOrder", .{
    .msg_type = .{ .type = .u8, .offset = 0 },
    .shares   = .{ .type = .u32, .offset = 1 },
});
```

At compile time, this generates:
- A typed `ParsedMessage` struct via `@Type`
- A `parse()` function using `std.mem.readInt` at comptime-known offsets
- A `toJSON()` serializer using `inline for` over fields

**Why?** Zero runtime overhead. The compiler generates direct memory reads at fixed offsets — no field lookup tables, no deserialization libraries, no allocations. Each protocol compiles to a handful of load instructions.

## Advanced Topics

### Adding New Core Features

1. **Understand the architecture** - Read relevant source files
2. **Maintain zero-cost abstractions** - Don't add runtime overhead
3. **Test thoroughly** - Unit tests + load tests + long-running tests
4. **Document** - Update USAGE.md and code comments

### Performance Profiling

```bash
# Build with debug symbols
zig build -Doptimize=ReleaseSafe

# Run under perf
perf record -g ./zig-out/bin/server --ports 8080

# Generate flamegraph (if perf-tools installed)
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg
```

### Memory Leak Detection

```bash
# Build with safe runtime checks
zig build -Doptimize=Debug

# Run with valgrind
valgrind --leak-check=full ./zig-out/bin/server --ports 8080

# Or use Zig's built-in leak detection
# (Automatically enabled with GeneralPurposeAllocator)
```

## Questions or Issues?

- Open an issue on GitHub
- Check existing documentation in `USAGE.md`
- Review example handlers in `handlers/`

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
