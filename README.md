# Zails

**High-performance server framework for Zig with zero virtual inheritance, zero mutexes, and zero allocations in the hot path.**

## Features

- **Convention-Based** — Drop files in `handlers/`, they're auto-linked at compile time
- **Comptime Dispatch** — All routing via `inline for` (zero cost, no vtables)
- **Lock-Free** — Atomic CAS, work-stealing threadpool, lock-free ring buffers
- **Zero Allocations** — Pre-allocated object pools, stack-allocated parse buffers
- **NUMA-Aware** — Workers pinned to NUMA nodes/CPUs
- **Protobuf Wire Format** — gRPC-style service registry with comptime routing
- **Message Bus** — Lock-free pub/sub event system with entity-owned topics and filtering
- **UDP Feed Ingestion** — Comptime binary protocol generator for exchange connectivity (ITCH, MDP3, etc.)
- **ClickHouse ORM** — ActiveRecord-like models with fluent query builder
- **Code Generators** — `zails create model/service/migration/scaffold`

## Quick Start

```bash
# Build
zig build

# Start server
./zig-out/bin/server --ports 8080

# Test
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
Worker Thread (NUMA-pinned)           toJSON() -> Event.initOwned()
  1. Read message type                      |
  2. Dispatch via inline for          MessageBus.publish()
  3. Execute handler                        |
  4. Return response                  Ring Buffer -> EventWorkers -> Subscribers
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
| Publish throughput | 42,538 events/sec |
| Publish P50 | 0.30 us |
| Publish P99 | 0.58 us |
| Publish P99.9 | 5.23 us |
| Ring buffer push | 0.8 us (3x improvement from cache-line alignment) |
| Ring buffer pop | 0.9 us |
| Allocations in publish path | 0 |

### UDP Binary Protocol

| Metric | Value |
|--------|-------|
| Parse (38-byte ITCH AddOrder) | < 100 ns |
| Parse + JSON serialize | < 1 us |
| Allocations in parse path | 0 |

## Documentation

- **[USAGE.md](USAGE.md)** — Installation, configuration, handlers, UDP feeds, testing
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — Architecture, code style, development workflow
- **[ROADMAP.md](ROADMAP.md)** — Feature roadmap and project status
- **[docs/](docs/)** — Message bus guides, memory management

## Requirements

- Zig 0.15.2 or later
- Linux (for NUMA support, epoll, multicast)
- Docker (optional, for ClickHouse metrics)

## License

MIT

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines, architecture principles, and testing procedures.
