# Zails

**High-performance server framework for Zig with zero virtual inheritance, zero mutexes, and zero allocations in the hot path.**

## Features

- **Importable Runtime** - Build apps with `const zails = @import("zails");` and `zails.App(.{ .handlers = ... })`.
- **Convention-Based Handlers** - Drop files in `handlers/`; `zails build` regenerates the handler registry.
- **Comptime Dispatch** - Routing uses `inline for` and compile-time registries instead of vtables or runtime hash maps.
- **Tiger Style Results** - Handlers return `HandlerResponse` values instead of throwing through the hot path.
- **Zero-Allocation Hot Paths** - Stack buffers, fixed payload slots, and pre-allocated queues keep request/event paths off the heap.
- **Lock-Free Core** - Atomic CAS queues, MPMC ring buffers, lock-free subscriber lookup, and pool-backed payload ownership.
- **NUMA-Aware TCP Server** - Linux epoll workers can be pinned across CPUs/NUMA nodes.
- **Custom gRPC-Style Protocol** - Protobuf-style request/response framing over TCP with comptime service routing.
- **Message Bus** - Kafka-like pub/sub with wildcard topics, typed field filters, background workers, and no filter-path allocation.
- **Reactive Models** - Atomic fields, optimistic versions, automatic update events, and stack-buffer JSON serialization.
- **UDP Feed Ingestion** - Comptime binary protocol generator for fixed-layout market-data style feeds.
- **ClickHouse ORM** - ActiveRecord-like model declarations with fluent query builders.
- **Foreign Handlers** - Call native C ABI handlers linked into the binary or out-of-process TCP workers.
- **C/C++ Runtime Headers** - `include/zails/zails.h` and `include/zails/zails.hpp` expose frame helpers and model views.
- **Same-Machine Zails Calls** - Loopback Zails-to-Zails requests can use a local registrar plus shared-memory ring buffer.
- **Code Generators** - `zails create model/service/migration/scaffold/config` and project scaffolding with native extension support.
- **Linux Docker Test Harness** - Aggregate tests include message bus, simulation, local IPC, runtime, and C++ integration coverage.

## Install

```bash
# Option 1: Install script
curl -fsSL https://raw.githubusercontent.com/tedkoomen/zails/main/install.sh | sh

# Option 2: Homebrew (macOS)
brew tap tedkoomen/zails
brew install zails

# Option 3: Download binary from GitHub Releases
# https://github.com/tedkoomen/zails/releases
```

## Quick Start

```bash
# Create a new project
zails init my-server
cd my-server

# Build and run
zails build
./zig-out/bin/server --ports 8080

# Test with the built-in client
./zig-out/bin/client 8080 1 "Hello, Zails!"
```

## Architecture

```
                                +---------------------+
                                |    zails.App(...)   |
                                |  comptime registry  |
                                +----------+----------+
                                           |
              +----------------------------+----------------------------+
              |                                                         |
       TCP/gRPC-style                                            Local runtime
        clients                                                  native calls
              |                                                         |
              v                                                         v
  +------------------------+                              +------------------------+
  | Listener / epoll loop  |                              | NativeForeignHandler   |
  | Linux worker threads   |                              | C ABI, linked in       |
  +-----------+------------+                              +-----------+------------+
              |                                                         |
              v                                                         |
  +------------------------+                                            |
  | HandlerRegistry        |<-------------------------------------------+
  | inline for dispatch    |
  +-----------+------------+
              |
              v
  +------------------------+       +----------------------+       +------------------+
  | Handler.handle(...)    |------>| MessageBus.publish() |------>| EventWorkers     |
  | HandlerResponse value  |       | MPMC ring buffer     |       | subscribers      |
  +-----------+------------+       +----------+-----------+       +---------+--------+
              |                               |                             |
              v                               v                             v
       TCP response                 PayloadPool for borrowed       filter.matches()
                                    event slices                   typed fields, 0 alloc
```

Zails keeps dispatch static and predictable: requests enter through TCP, native C ABI, or local Zails proxy handlers, then converge on the same comptime handler registry and Tiger Style `HandlerResponse` contract.

### Request Flow

```
Client request
    |
    v
TCP socket / epoll
    |
    v
Worker thread
    |
    v
Message type decode
    |
    v
HandlerRegistry inline dispatch
    |
    v
Handler.handle(context, request, response_buffer, allocator)
    |
    v
HandlerResponse.ok(bytes) or HandlerResponse.err(error)
    |
    v
TCP response write
```

Handlers are ordinary Zig types with a `MESSAGE_TYPE`, `Context`, and `handle` function. The registry is generated at compile time, so the runtime path does not need dynamic dispatch.

### Core Components

| Component | Files | Purpose |
|-----------|-------|---------|
| Runtime API | `src/runtime.zig` | Public import surface for apps using Zails as a runtime |
| Handler registry | `src/handler_registry.zig`, `handlers/mod.zig` | Comptime message-type dispatch |
| TCP server | `src/main.zig`, `src/epoll_worker.zig`, `src/server_framework.zig` | Linux listener, epoll workers, socket IO |
| Result model | `src/result.zig` | Tiger Style `HandlerResponse` and `ServerError` values |
| Foreign handlers | `src/foreign_handler.zig` | Native C ABI, TCP workers, and Zails proxy handlers |
| Local IPC | `src/local_ipc.zig` | Registrar and shared-memory ring transport for loopback Zails calls |
| Events | `src/event.zig`, `src/message_bus/event_builder.zig` | Event payloads, typed fields, and event construction |
| Message bus | `src/message_bus/message_bus.zig` | Publish, backpressure/drop behavior, worker lifecycle |
| Ring buffer | `src/message_bus/ring_buffer.zig` | MPMC sequence-number queue for event delivery |
| Payload pool | `src/message_bus/payload_pool.zig` | Fixed-slot borrowed payload ownership |
| Subscribers | `src/message_bus/lockfree_subscriber_registry.zig` | Lock-free subscription storage and matching |
| Reactive models | `src/experimental/reactive_model.zig` | Atomic model fields, versions, JSON snapshots, update events |
| UDP protocols | `src/udp/` | Comptime binary protocol parsing and feed support |
| ORM | `src/orm/` | ClickHouse model definitions and query builder |
| CLI/generators | `src/zails.zig` | `zails init`, build, generators, and project scaffolding |
| C/C++ headers | `include/zails/` | ABI constants, frame helpers, and C++ model views |

### Runtime Module

Applications can import Zails as a module:

```zig
const zails = @import("zails");

const App = zails.App(.{
    .handlers = .{ MyHandler },
});

pub const Registry = App.Registry;
```

The public runtime surface exports handler results, the message bus, events, filters, reactive models, ORM helpers, protobuf/gRPC helpers, local IPC, and foreign-handler adapters.

### Runtime Extension Examples

Native C ABI handlers can be compiled into the same binary:

```zig
fn nativeEcho(
    request_ptr: [*]const u8,
    request_len: usize,
    response_ptr: [*]u8,
    response_cap: usize,
) callconv(.c) zails.CHandlerResult {
    if (request_len > response_cap) return zails.nativeErr(.message_too_large);
    @memcpy(response_ptr[0..request_len], request_ptr[0..request_len]);
    return zails.nativeOk(request_len);
}

const EchoHandler = zails.NativeForeignHandler(50, nativeEcho);
```

Out-of-process workers use the fixed Zails foreign frame protocol:

```zig
const PythonWorker = zails.TcpForeignHandler(.{
    .message_type = 51,
    .host = "127.0.0.1",
    .port = 9001,
    .timeout_us = 2_000_000,
});
```

Reactive models expose typed fields and publish events on mutation:

```zig
const Trade = zails.ReactiveModel("Trade", .{
    .symbol = .String,
    .price = .i64,
    .quantity = .u64,
    .active = .bool,
});
```

### Foreign Handler Architecture

```
Zails handler registry
    |
    +--> NativeForeignHandler
    |       |
    |       v
    |   linked C ABI function
    |
    +--> TcpForeignHandler
    |       |
    |       v
    |   fixed 32-byte frame over TCP
    |       |
    |       v
    |   Python / C++ / Rust / Node / other worker
    |
    +--> ZailsProxyHandler
            |
            v
        local IPC if loopback registrar exists,
        otherwise caller can use TCP fallback paths
```

Foreign handlers use the same Tiger Style result model. Native handlers return `zails_handler_result_t`; TCP workers exchange request/response frames with explicit error codes.

### Same-Machine IPC

```
Zails server startup
    |
    v
/tmp/zails/ports/<port> registrar entry
    |
    v
/tmp/zails/shm/<server-ring> mmap file
    |
    v
Loopback client detects registrar
    |
    v
Shared-memory request slot
    |
    v
Server local IPC worker dispatches through HandlerRegistry
    |
    v
Shared-memory response slot
```

Local IPC is opportunistic: it is used only for loopback destinations with a valid registrar and ring. If validation fails or the target is not local, callers can continue through TCP worker paths.

### Message Bus Architecture

```
Publisher / model mutation
    |
    v
EventBuilder or Event.setField()
    |
    v
MessageBus.publish()
    |
    v
PayloadPool copies borrowed slices into fixed slots
    |
    v
MPMC EventRingBuffer
    |
    v
EventWorker threads
    |
    v
LockFreeSubscriberRegistry.matchingIterator()
    |
    v
Filter.matches(event fields)
    |
    v
subscriber callback
```

Events carry raw payload bytes plus up to 8 typed fields. Filters operate on typed fields only, so filtering avoids JSON parsing and allocator traffic.

### UDP Feed Architecture

```
UDP multicast/unicast datagram
    |
    v
UdpListener
    |
    v
BinaryProtocol.parse()
    |
    v
comptime field offsets -> typed ParsedMessage
    |
    v
Event + typed fields
    |
    v
MessageBus.publish()
```

**Zero virtual inheritance. Zero runtime dispatch in handler routing. Zero allocations in UDP parse and filter matching.**

## Defining a Binary Protocol

```zig
const udp = @import("udp/mod.zig");

pub const AddOrder = udp.BinaryProtocol("ITCH_AddOrder", .{
    .msg_type     = .{ .type = .u8,    .offset = 0 },
    .stock_locate = .{ .type = .u16,   .offset = 1 },
    .timestamp_ns = .{ .type = .u64,   .offset = 3 },
    .order_ref    = .{ .type = .u64,   .offset = 11 },
    .side         = .{ .type = .u8,    .offset = 19 },
    .shares       = .{ .type = .u32,   .offset = 20 },
    .stock        = .{ .type = .ascii, .offset = 24, .size = 8 },
    .price        = .{ .type = .u32,   .offset = 32 },
});
```

At compile time, this generates a typed `ParsedMessage` struct, a `parse()` function that extracts fields at known offsets with zero copying, and a `toJSON()` serializer. No runtime overhead.

## Performance

### TCP Server

Measured on loopback (4-core VM). Production estimates in parentheses.

| Metric | Value |
|--------|-------|
| Throughput | 13,667 req/s (100 clients) |
| Peak throughput | 15,151 req/s |
| Success rate | 100% (161,001 requests, zero failures) |
| P50 latency | 609 us loopback (~80 us production) |
| P99 latency | 16.7 ms loopback |
| Syscalls per request | 3 (epoll_wait, read, writev) |
| Allocations per request | 0 |

### Message Bus

100,000 events published, 10 subscribers, 4 workers (4-core VM):

| Metric | Value |
|--------|-------|
| Publish throughput | 46,112 events/sec |
| Publish P50 | 0.04 us |
| Publish P99 | ~1.5 us |
| Throughput (1 subscriber) | ~600k events/sec |
| Allocations in publish path | 0 |

### Event Filtering

`filter.matches()` uses typed field slots on the Event struct — no JSON parsing, no heap allocation. Measured in a tight loop (10M iterations, ReleaseFast):

| Scenario | ns/op |
|----------|-------|
| Empty filter (0 conditions) | 0 ns |
| Single int condition (`price > 5000`) | 15 ns |
| Single string condition (`symbol == AAPL`) | 10 ns |
| Two conditions AND | 21 ns |
| Missing field (early exit) | 3 ns |
| Worst case (8 fields, 4 conditions) | 58 ns |
| Allocations in filter path | **0** |

Events carry up to 8 typed fields (`FieldValue`: int, uint, float, string, bool) in stack-allocated fixed buffers. The raw `data` payload is format-agnostic and never touched by filters.

### UDP Binary Protocol

| Metric | Value |
|--------|-------|
| Parse (38-byte ITCH AddOrder) | < 100 ns |
| Parse + JSON serialize | < 1 us |
| Allocations in parse path | 0 |

## Benchmarks

```bash
# Build benchmarks (always use ReleaseFast for accurate numbers)
zig build message-bus-bench -Doptimize=ReleaseFast
zig build heartbeat-bench -Doptimize=ReleaseFast
zig build allocation-probe -Doptimize=ReleaseFast

# Filter microbenchmark — raw filter.matches() ns/op
./zig-out/bin/message_bus_benchmark --mode filter-micro --events 10000000

# Filter end-to-end — delivery with typed field filters
./zig-out/bin/message_bus_benchmark --mode filter --events 100000 --subscribers 10

# Publish latency (P50/P90/P99)
./zig-out/bin/message_bus_benchmark --mode latency --events 100000

# Max throughput
./zig-out/bin/message_bus_benchmark --mode throughput --duration 5

# Stress test (many subscribers, multiple topics)
./zig-out/bin/message_bus_benchmark --mode stress --subscribers 50 --duration 10

# Allocation probe — verifies hot paths on clean and fragmented heaps
./zig-out/bin/allocation_probe
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `zails init <name>` | Create a new project |
| `zails build` | Regenerate handler registry and compile |
| `zails create handler <name>` | Generate a handler |
| `zails create model <name> [--table=...]` | Generate an ORM model |
| `zails create service <name>` | Generate a gRPC service handler |
| `zails create migration <name>` | Generate a database migration |
| `zails create config` | Generate configuration files |
| `zails scaffold <name> [--fields=...]` | Generate model + migration + service |
| `zails help` | Show help |

## Documentation

- **[USAGE.md](USAGE.md)** — Installation, configuration, handlers, UDP feeds, testing
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — Architecture, code style, development workflow
- **[ROADMAP.md](ROADMAP.md)** — Feature roadmap and project status
- **[docs/](docs/)** — Message bus guides, memory management
- **[docs/guides/getting_started.md](docs/guides/getting_started.md)** — Step-by-step new project guide

## Requirements

- The `zails` CLI is a standalone binary — no dependencies needed to create projects
- [Zig](https://ziglang.org/download/) 0.15.2 or later (to build generated projects)
- Linux (for NUMA support, epoll, multicast)
- Docker (optional, for ClickHouse metrics)

## License

MIT

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines, architecture principles, and testing procedures.
