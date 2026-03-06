# Zails Usage Guide

**Convention-based server framework for Zig with zero virtual inheritance, zero mutexes, and zero allocations in the hot path.**

## Quick Start

```bash
# Build the server
zig build

# Start server on port 8080
./zig-out/bin/server --ports 8080

# Test with client
./zig-out/bin/client 8080 1 "Hello, Zails!"
```

## Table of Contents

- [Installation](#installation)
- [Basic Usage](#basic-usage)
- [Configuration](#configuration)
- [Adding Handlers](#adding-handlers)
- [UDP Feed Ingestion](#udp-feed-ingestion)
- [Message Bus](#message-bus)
- [Testing](#testing)
- [ClickHouse Integration](#clickhouse-integration)
- [Protocol](#protocol)
- [Advanced Topics](#advanced-topics)

## Installation

### Requirements

- Zig 0.15.2 or later
- Linux (for NUMA support)
- OpenSSL (optional, for TLS)
- Docker (optional, for ClickHouse metrics)

### Build

```bash
zig build
```

This creates:
- `./zig-out/bin/server` - Production server
- `./zig-out/bin/client` - Test client
- `./zig-out/bin/test_harness` - Load tester
- `./zig-out/bin/zails` - CLI tool

## Basic Usage

### Starting the Server

```bash
# Single port
./zig-out/bin/server --ports 8080

# Multiple ports
./zig-out/bin/server --ports 8080,8081,8082

# Custom worker count
./zig-out/bin/server --ports 8080 --workers 16

# Disable NUMA
./zig-out/bin/server --ports 8080 --no-numa

# Using startup script (auto-detects config)
./scripts/start-server.sh --ports 8080
```

### Using the Client

```bash
# Echo handler (MESSAGE_TYPE = 1)
./zig-out/bin/client 8080 1 "Hello, Zails!"

# Ping handler (MESSAGE_TYPE = 2)
./zig-out/bin/client 8080 2
```

## Configuration

### Command-Line Options

```bash
./server --help

Options:
  -p, --ports <ports>           Comma-separated list of ports (required)
                                Example: --ports 8080,8081,8082
  -w, --workers <count>         Number of worker threads (default: auto)
  --numa                        Enable NUMA awareness (default)
  --no-numa                     Disable NUMA awareness
  --buffer-size <bytes>         Buffer size (default: 4096)
  --pool-size <count>           Object pool size per worker (default: 1024)
  --max-connections <count>     Maximum concurrent connections (default: 10000)
  -h, --help                    Show this help message
```

### Configuration File

Create `config/zails.yaml`:

```yaml
server:
  ports: [8080, 8081]
  workers: 16
  numa_enabled: true
  buffer_size: 4096
  pool_size: 1024
  max_connections: 10000

persistence:
  enabled: false
  backend: clickhouse

  clickhouse:
    enabled: false
    url: "http://localhost:8123"
    database: "zails"
    batch_size: 1000
    flush_interval_ms: 1000
```

## Adding Handlers

### Step 1: Create Handler File

Create `handlers/my_handler.zig`:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

// Message type ID (must be unique)
pub const MESSAGE_TYPE: u8 = 42;

// Your handler's state/context
pub const Context = struct {
    request_count: std.atomic.Value(u64),

    pub fn init() Context {
        return .{
            .request_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Context) void {
        _ = self;
        // Cleanup if needed
    }
};

// Your business logic
pub fn handle(
    context: *Context,
    request_data: []const u8,
    response_buffer: []u8,
    allocator: Allocator,
) ![]const u8 {
    _ = context.request_count.fetchAdd(1, .monotonic);

    // Process request_data
    // Write response to response_buffer
    // Return slice of response

    return response_buffer[0..0]; // Your response here
}
```

### Step 2: Register in mod.zig

Edit `handlers/mod.zig`:

```zig
pub const my_handler = @import("my_handler.zig");

pub const handler_modules = .{
    echo_handler,
    ping_handler,
    my_handler,  // ← Add here
};
```

### Step 3: Rebuild

```bash
zig build
```

**That's it!** Your handler is now automatically:
- Linked at compile time
- Validated for correct interface
- Dispatched via comptime `inline for`
- Available on all server ports

## UDP Feed Ingestion

Zails supports receiving binary data over UDP for exchange connectivity (market data feeds like ITCH, MDP3, OUCH). Protocols are defined at compile time for zero-overhead parsing. Runtime configuration specifies which ports to bind and which protocol to use on each.

### Defining a Binary Protocol

Create a protocol definition file in `src/protocols/`:

```zig
// src/protocols/my_feed.zig
const udp = @import("../udp/mod.zig");

pub const PROTOCOL_ID: u8 = 2;
pub const TOPIC = "Feed.my_feed";

pub const MyMessage = udp.BinaryProtocol("MyFeed_Message", .{
    .msg_type     = .{ .type = .u8,    .offset = 0 },
    .sequence     = .{ .type = .u32,   .offset = 1 },
    .timestamp_ns = .{ .type = .u64,   .offset = 5 },
    .value        = .{ .type = .u32,   .offset = 13 },
    .symbol       = .{ .type = .ascii, .offset = 17, .size = 8 },
});
```

Supported field types: `u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`, `i64`, `f32`, `f64`, `ascii` (fixed-width string), `raw_bytes`.

Fields default to big-endian (network byte order). Override with `.endian = .little` per field.

### Registering Protocols

Add your protocol to the protocol tuple in `src/main.zig`:

```zig
const my_feed = @import("protocols/my_feed.zig");
const example_itch = @import("protocols/example_itch.zig");

const FeedProtocols = .{
    .{ .PROTOCOL_ID = example_itch.PROTOCOL_ID, .Parser = example_itch.AddOrder, .TOPIC = example_itch.TOPIC },
    .{ .PROTOCOL_ID = my_feed.PROTOCOL_ID,      .Parser = my_feed.MyMessage,     .TOPIC = my_feed.TOPIC },
};
```

Each `PROTOCOL_ID` must be unique. The compiler will error if duplicates are detected.

### Configuring Feeds at Runtime

Feed configuration specifies which UDP ports to bind and which protocol to use:

```zig
// In config or programmatically:
const feed_config = udp.FeedConfig{
    .name = "nasdaq_itch_a",
    .bind_address = "0.0.0.0",
    .bind_port = 26400,
    .multicast_group = "239.1.2.3",       // null for unicast
    .multicast_interface = "10.0.1.1",    // null for INADDR_ANY
    .protocol_id = 1,                     // Maps to PROTOCOL_ID in tuple
    .enabled = true,
    .recv_buffer_size = 16 * 1024 * 1024, // 16MB SO_RCVBUF
    .publish_topic = "Feed.itch",
    .initial_sequence = 0,                // Starting sequence for gap detection
};
```

Or use the convenience helper:

```zig
const feed_config = udp.defaultFeedConfig("my_feed", 5000, 1, "Feed.itch");
// Binds 0.0.0.0:5000, protocol_id=1, 16MB recv buffer, no multicast
```

### Multicast

To join a multicast group, set `multicast_group` to the group address (e.g., `"239.1.2.3"`). Optionally set `multicast_interface` to the IP of the network interface to use. The listener calls `IP_ADD_MEMBERSHIP` on socket init.

### Data Flow

```
Exchange Multicast (239.x.x.x:port)
    |
UdpListener.recvfrom() -> recv_buffer (stack, 64KB)
    |
dispatchParse() -> inline for over Protocols (comptime, zero overhead)
    |
BinaryProtocol.parse(datagram) -> ParsedMessage (stack-allocated struct)
    |
BinaryProtocol.toJSON(msg) -> JSON bytes (stack buffer)
    |
Event.initOwned(allocator, topic, data) -> owned Event (heap copy)
    |
MessageBus.publish(event) -> ring buffer -> EventWorkers -> Subscribers
```

### Monitoring Feed Stats

```zig
// Get per-feed stats
const stats = listener.getStats();
// stats.datagrams_received, stats.parse_errors, stats.bytes_received, stats.events_published

// Get aggregate stats across all feeds
const agg = feed_manager.getStats();
// agg.active_feeds, agg.datagrams_received, agg.parse_errors, etc.

// Sequence gap detection
const seq_stats = listener.getSequenceTracker().getStats();
// seq_stats.expected_seq, seq_stats.gaps_detected, seq_stats.duplicates
```

### Example: ITCH Protocol

See `src/protocols/example_itch.zig` for a reference implementation defining AddOrder (38 bytes), Trade (46 bytes), and OrderCancel (25 bytes) message types.

---

## Message Bus

The message bus provides lock-free pub/sub event delivery across the server.

### Publishing Events

```zig
const Event = @import("event.zig").Event;

const event = try Event.initOwned(
    allocator,
    .custom,
    "Feed.itch",         // topic
    "ITCH_AddOrder",     // model_type
    0,                   // model_id
    json_data,           // payload
);
bus.publish(event);
// Event ownership transfers to the bus; do not use event after publish
```

### Subscribing to Events

```zig
const filter = Filter{ .conditions = &.{} }; // No filter (receive all)
const sub_id = try bus.subscribe("Feed.*", filter, myHandler);

fn myHandler(event: *const Event) void {
    // Process event.data (JSON payload)
}
```

### Topics

Topics are declared by the entities that own them and validated at compile time by format:

```zig
message_bus.ModelTopics("User").created   // "User.created"
message_bus.ModelTopics("Item").wildcard  // "Item.*"
message_bus.CustomTopic("Order.completed")
message_bus.FeedTopics("itch").received   // "Feed.itch"
message_bus.SystemTopics.startup          // "System.startup"
```

No central registry — just use `ModelTopics("YourEntity")` or `CustomTopic("Your.event")`. Topic format is validated at compile time (must be `"Category.event"`).

---

## Testing

### Manual Testing

```bash
# Start server
./zig-out/bin/server --ports 8080

# Test echo handler
./zig-out/bin/client 8080 1 "Test message"

# Test ping handler
./zig-out/bin/client 8080 2
```

### Load Testing

Basic load test:
```bash
./zig-out/bin/test_harness 8080 50 10000
#                           port clients reqs/client
```

Duration-based testing:
```bash
# Run for 5 minutes with 100 clients, reporting progress every 30s
./zig-out/bin/test_harness 8080 100 --duration=300 --progress=30

# Hybrid mode: stop after 10 minutes OR 1M requests (whichever first)
./zig-out/bin/test_harness 8080 50 --duration=600 --requests=20000 --hybrid --progress=60
```

Test harness options:
```bash
./zig-out/bin/test_harness --help

Options:
  --duration=N    - Run for N seconds (enables duration mode)
  --requests=N    - Override requests per client
  --progress=N    - Show progress every N seconds
  --hybrid        - Use both duration and request limits
```

### UDP Feed Tests

```bash
# Run all tests (includes UDP feed tests)
zig build test

# Run binary protocol tests only (self-contained, no external deps)
zig test src/udp/binary_protocol.zig

# Run sequence tracker tests only
zig test src/udp/sequence_tracker.zig
```

The UDP listener integration tests automatically bind to localhost with an OS-assigned port, send crafted datagrams, and verify parse results. No external services needed.

### Understanding Results

```
=== Load Test Results ===
Test Mode:          duration
Duration Limit:     300s

Total Requests:     50000
Successful:         49998 (99.9%)
Failed:             2 (0.1%)
Total Duration:     8523ms (8.52s)

Latency (microseconds):
  Average:          85.3µs
  P50:              72µs
  P95:              145µs
  P99:              312µs

Throughput:         5865.2 req/s
```

**Good Performance:**
- Success rate >99.9%
- P99 latency <1ms
- Throughput >100K req/s (for 4-core machine)

## ClickHouse Integration

### Enable ClickHouse

Edit `config/zails.yaml`:

```yaml
persistence:
  enabled: true
  backend: clickhouse

  clickhouse:
    enabled: true
    url: "http://localhost:8123"
    database: "zails"
```

### Start with ClickHouse

The startup script automatically starts ClickHouse:

```bash
# This will:
# - Start ClickHouse Docker container
# - Create database and schema
# - Start the Zails server
./scripts/start-server.sh --ports 8080
```

### Verify ClickHouse

```bash
# Check container
docker ps | grep clickhouse

# Query metrics
curl 'http://localhost:8123/?query=SELECT+count()+FROM+zails.zails_request_metrics'
```

### Query Metrics

```bash
# Total requests
curl 'http://localhost:8123/?query=SELECT+count()+FROM+zails.zails_request_metrics'

# Latest 10 requests
curl 'http://localhost:8123/?query=SELECT+*+FROM+zails.zails_request_metrics+ORDER+BY+timestamp+DESC+LIMIT+10+FORMAT+PrettyCompact'

# Latency by handler
curl 'http://localhost:8123/?query=SELECT+handler_name,count()+as+requests,avg(latency_us)+as+avg_latency_us+FROM+zails.zails_request_metrics+GROUP+BY+handler_name+FORMAT+PrettyCompact'

# Error rate
curl 'http://localhost:8123/?query=SELECT+handler_name,countIf(error_code>0)+as+errors,count()+as+total+FROM+zails.zails_request_metrics+GROUP+BY+handler_name+FORMAT+PrettyCompact'
```

### Manual ClickHouse Management

```bash
# Start ClickHouse only
./scripts/start-clickhouse.sh

# Stop ClickHouse
docker stop zails-clickhouse

# Remove ClickHouse (deletes data)
docker rm -f zails-clickhouse

# Start server without ClickHouse
./scripts/start-server.sh --ports 8080 --skip-clickhouse
```

## Protocol

Messages use a simple framing protocol:

```
[1 byte: message type][4 bytes: length, big-endian][N bytes: protobuf data]
```

Example:
```
0x01 0x00 0x00 0x00 0x0A [...10 bytes of protobuf...]
└─┘  └────────────┘       └───────────────────┘
Type    Length=10              Protobuf data
```

## Advanced Topics

### Thread Safety

Handlers run concurrently. Use atomics for shared state:

```zig
pub const Context = struct {
    counter: std.atomic.Value(u64),  // ✓ Thread-safe
    // NOT: counter: u64,             // ✗ Race condition!
};
```

### Zero-Copy Responses

Write directly to `response_buffer`:

```zig
pub fn handle(..., response_buffer: []u8, ...) ![]const u8 {
    std.mem.writeInt(u64, response_buffer[0..8], value, .big);
    return response_buffer[0..8];  // Zero copy!
}
```

### Protobuf Integration

Use `proto.zig` for encoding/decoding:

```zig
const proto = @import("proto.zig");

var request = try proto.decodeEchoRequest(allocator, request_data);
defer request.deinit(allocator);

// ... process ...

const len = try proto.encodeEchoResponse(&response, response_buffer);
return response_buffer[0..len];
```

### Per-Handler Configuration

Create `handlers/my_handler.yaml`:

```yaml
capture_payload: true        # Log full request/response in ClickHouse
custom_setting: "value"      # Your custom settings
```

Access in handler:

```zig
pub fn handle(context: *Context, ...) ![]const u8 {
    if (context.config.capture_payload) {
        // Log full payload
    }
}
```

## Troubleshooting

### Server won't start

```bash
# Check if port is in use
sudo lsof -i :8080

# View full logs
./scripts/start-server.sh --ports 8080 2>&1 | tee server.log
```

### ClickHouse container fails to start

```bash
# Check Docker
docker ps -a

# View ClickHouse logs
docker logs zails-clickhouse

# Clean start
docker rm -f zails-clickhouse
./scripts/start-clickhouse.sh
```

### High latency / low throughput

```bash
# Check NUMA configuration
numactl --hardware

# Try disabling NUMA
./zig-out/bin/server --ports 8080 --no-numa

# Increase worker count
./zig-out/bin/server --ports 8080 --workers 32

# Increase pool size
./zig-out/bin/server --ports 8080 --pool-size 4096
```

## Performance Tips

1. **Use NUMA** - Keep NUMA enabled on multi-socket systems
2. **Tune workers** - Set to number of physical cores (not hyperthreads)
3. **Increase pool size** - For high concurrency, use larger pools
4. **Disable ClickHouse** - For maximum throughput, disable metrics collection
5. **Use multiple ports** - Spread load across ports to reduce contention

## Architecture

```
Client Request
      ↓
[1 byte: type][4 bytes: length][N bytes: protobuf]
      ↓
Listener Thread (NUMA-pinned)
      ↓
Lock-Free Work Queue (atomic CAS)
      ↓
Worker Thread (NUMA-pinned)
  1. Pop work (atomic CAS)
  2. Read message type
  3. Dispatch via comptime inline for ← DIRECT CALL
  4. Execute handler business logic
  5. Return response
      ↓
Response to Client

ZERO syscalls in steps 2-5!
ZERO allocations!
ZERO virtual inheritance!
```

## License

MIT - See LICENSE file for details
