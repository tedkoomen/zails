# Zails

**High-performance server framework for Zig with zero virtual inheritance, zero mutexes, and zero allocations in the hot path.**

## Features

- **Convention-Based** — Drop files in `handlers/`, they're auto-linked at compile time
- **Comptime Dispatch** — All routing via `inline for` (zero cost, no vtables)
- **Lock-Free** — Atomic CAS, work-stealing threadpool, lock-free ring buffers
- **Zero Allocations** — Pre-allocated object pools, stack-allocated parse buffers
- **NUMA-Aware** — Workers pinned to NUMA nodes/CPUs
- **Protobuf Wire Format** — gRPC-style service registry with comptime routing
- **Message Bus** — Lock-free pub/sub event system with entity-owned topics and zero-allocation typed field filtering
- **UDP Feed Ingestion** — Comptime binary protocol generator for exchange connectivity (ITCH, MDP3, etc.)
- **ClickHouse ORM** — ActiveRecord-like models with fluent query builder
- **Code Generators** — `zails create model/service/migration/scaffold`

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
TCP Client Request                     UDP Exchange Feed
      |                                     |
[type][length][protobuf]              [multicast datagram]
      |                                     |
Listener Thread (NUMA-pinned)         UdpListener (per-feed thread)
      |                                     |
Lock-Free Work Queue (CAS)           BinaryProtocol.parse() [comptime, stack]
      |                                     |
Worker Thread (NUMA-pinned)           Event + setField() [typed, stack-allocated]
  1. Read message type                      |
  2. Dispatch via inline for          MessageBus.publish()
  3. Execute handler                        |
  4. Return response                  Ring Buffer -> EventWorkers
                                            |
                                      filter.matches() [0 alloc, 15ns/op]
                                            |
                                      Matched Subscribers -> Handler Callbacks
      |
Response to Client
```

**Zero syscalls in handler dispatch. Zero allocations in UDP parse path. Zero virtual inheritance.**

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
