# Zails Framework Roadmap

## Vision

Transform Zails into a high-performance **gRPC version of Rails** for Zig, combining:
- **gRPC + Protocol Buffers** for the protocol layer (maintaining sub-150µs latency)
- **ActiveRecord-like ORM** for ClickHouse database access
- **Convention-over-configuration** with powerful code generators
- **Event-driven architecture** with message bus for real-time updates
- **UDP feed ingestion** for exchange connectivity and market data

## Performance Targets

| Metric | Current | Target | Strategy |
|--------|---------|--------|----------|
| P50 Latency | 69µs | < 150µs | Keep TCP transport, avoid HTTP/2 overhead |
| Encoding Overhead | N/A | < 5µs | Optimize protobuf encoding in proto.zig |
| Service Routing | < 1µs | < 2µs | Comptime dispatch (zero vtable) |
| ORM Query Building | N/A | < 10µs | Stack-allocated query builders |
| Throughput | 10k+ req/s | 50k+ req/s | Lock-free pools, zero allocations |
| UDP Parse | N/A | < 1µs | Comptime field extraction, stack-allocated |
| Success Rate | 100% | 100% | Tiger Style error handling |

## Core Principles

1. **Tiger Style** - Errors as values, never throws
2. **Zero Allocations** - Lock-free object pools in hot path
3. **Comptime Everything** - No runtime dispatch, no vtables
4. **Convention-based** - Auto-discovery, minimal boilerplate
5. **NUMA-aware** - Automatic worker placement
6. **Sub-100µs Latency** - Every design decision optimized for speed

---

## Completed Phases

### Phase 1: gRPC Protocol Integration

**Status:** Complete

- `GrpcRequest` and `GrpcResponse` message types with full protobuf encoding/decoding
- `GrpcServiceRegistry` with comptime routing (service.method to MESSAGE_TYPE, zero overhead)
- `GrpcHandlerAdapter` wrapping existing handlers with automatic error mapping
- Compile-time validation for duplicate detection; no hash maps, no runtime lookups
- Wire format: `[TYPE=250][length][GrpcRequest]`

**Files:** `src/proto.zig`, `src/grpc_registry.zig`, `src/grpc_handler_adapter.zig`

---

### Phase 2: ClickHouse ORM

**Status:** Complete

- Fluent query builder API (`.select()`, `.where()`, `.orderBy()`, `.limit()`, `.groupBy()`)
- Stack-allocated builders generating ClickHouse-optimized SQL
- `Model()` function with auto-generated CRUD methods and CREATE TABLE SQL
- Full ClickHouse type system (UInt*, Int*, Float*, String, DateTime64, UUID, LowCardinality, Nullable)
- HTTP client with connection pooling, JSONEachRow/JSONCompact format support

**Files:** `src/orm/query_builder.zig`, `src/orm/model.zig`, `src/orm/field_types.zig`, `src/clickhouse_client.zig`

---

### Phase 3: Code Generators

**Status:** Complete

- `zails create model User --table=users` — generates ORM model with auto table name inference
- `zails create migration add_email_to_users` — timestamped migration with UP/DOWN SQL
- `zails create service UserService` — gRPC service handler with auto MESSAGE_TYPE assignment
- `zails scaffold Post --fields=title:String` — full model + migration + service generation

**Files:** `src/zails.zig`, `templates/*.template`

---

### Phase 4: Event-Driven Architecture

**Status:** Complete

- **Message Bus** — Lock-free ring buffer event queue with configurable worker threads
- **Entity-Owned Topics** — Decentralized compile-time topic declarations via `ModelTopics`, `FeedTopics`, `CustomTopic`
- **Pub/Sub** — `bus.subscribe(topic, filter, handler)` with wildcard support
- **Event Workers** — Background threads drain queue and deliver to subscribers
- **Lock-free Subscriber Registry** — Atomic subscriber management, no mutexes
- **Filter System** — Per-subscription event filtering
- **Handler Integration** — Handlers can publish and subscribe via `global_message_bus`

**Files:** `src/message_bus/` (message_bus.zig, ring_buffer.zig, event_worker.zig, subscriber.zig, filter.zig, lockfree_subscriber_registry.zig, model_topics.zig, system_topics.zig, mod.zig), `src/event.zig`

---

### Phase 5: UDP Feed Support for Exchange Connectivity

**Status:** Complete

- **Comptime BinaryProtocol Generator** — Define binary protocols with field type/offset/size; generates zero-cost parsers at compile time via `@Type` struct generation. Supports u8-u64, i8-i64, f32/f64, ASCII strings, raw bytes. Per-field endianness configuration (`.big` default for network byte order, `.little` override per field) enables mixed-endian protocols common in exchange feeds.
- **UdpListener** — Binds UDP sockets, joins multicast groups (`IP_ADD_MEMBERSHIP`), non-blocking recv loop with comptime `inline for` dispatch to matching parser. Stack-allocated parse and JSON serialize buffers (zero allocation in parse path, one allocation per event for bus ownership).
- **FeedManager** — Manages multiple listener threads from runtime config. Spawn/join lifecycle, aggregate stats across all feeds.
- **Sequence Tracker** — Lock-free gap detection and duplicate detection using atomics. Tracks expected sequence, counts gaps/duplicates/total checked.
- **Configuration** — Runtime `FeedConfig` specifies bind address/port, multicast group, protocol ID, recv buffer size, publish topic. Protocol layouts are comptime-only; runtime config maps ports to protocols.
- **Integration** — Parsed messages are serialized to JSON and published as `Event` objects on the message bus. Subscribers receive market data events on `Feed.*` topics.

**Files:** `src/udp/` (binary_protocol.zig, udp_listener.zig, feed_manager.zig, feed_config.zig, sequence_tracker.zig, mod.zig), `src/protocols/example_itch.zig`

**Test coverage:** 100 tests passing across the full codebase, including:
- 22 binary_protocol tests (parse, endianness, JSON, edge cases)
- 12 sequence_tracker tests (gaps, duplicates, concurrent access)
- 7 udp_listener tests (localhost send/receive, parse errors, unmatched protocol)
- 3 feed_manager tests (compile checks, stats defaults)
- 2 feed_config tests (defaults, field layout)

---

## Next Phases

### Phase 6: Advanced ORM Features

**Status:** Planned — Next up

#### 6.1 Query Result Parsing
- JSONCompact parser for SELECT results
- TabSeparated parser (faster for large datasets)
- Automatic struct mapping from query results
- Streaming result iteration (cursor support)

#### 6.2 Aggregation Support
- `.sum()`, `.avg()`, `.min()`, `.max()` in addition to existing `.count()`
- `.groupBy()` with aggregations
- `.having()` clause support
- Window functions (ClickHouse-specific)

#### 6.3 Joins and Relations
- `.join()`, `.leftJoin()`, `.innerJoin()`
- Relationship definitions (hasMany, belongsTo)
- Eager loading (N+1 prevention)

#### 6.4 Data Validation
- Model-level validators
- Type checking before insert
- Custom validation rules with error messages

---

### Phase 7: Migration System

**Status:** Planned

#### 7.1 Migration Runner
- Execute migrations in order
- Track applied migrations (schema_migrations table)
- Rollback support (down migrations)
- Dry-run mode

#### 7.2 Schema Management
- `zails migrate` — run pending migrations
- `zails migrate:rollback` — rollback last migration
- `zails migrate:status` — show migration status

#### 7.3 Schema Diffing
- Detect schema changes automatically
- Generate migrations from model changes
- `zails migrate:generate` — auto-create migration

#### 7.4 Seed Data
- `seeds/` directory for test data
- `zails db:seed` command
- Environment-specific seeds

---

### Phase 8: Advanced Feed Features

**Status:** Planned

#### 8.1 Batch Receive
- `recvmmsg` for high-throughput feeds (100k+ msg/s)
- Configurable batch sizes per feed
- Reduced syscall overhead

#### 8.2 Feed Protocol Expansion
- MDP3 (CME Market Data) protocol definition
- OUCH (order entry) protocol definition
- ITCH 5.0 full message set (beyond AddOrder/Trade/Cancel)
- Protocol versioning support

#### 8.3 Feed Replay and Recovery
- Gap fill requests via TCP retransmission channel
- Snapshot recovery on startup
- Persist last-known sequence to disk for crash recovery
- Event sourcing integration (replay from ClickHouse)

#### 8.4 Feed Health Monitoring
- Per-feed latency tracking (receive timestamp vs message timestamp)
- Stale feed detection (no messages for N seconds)
- Gap rate alerting (threshold-based)
- Feed stats exposed via metrics endpoint

#### 8.5 NUMA-Aware Feed Threads
- Pin feed listener threads to specific NUMA nodes
- Dedicated recv buffer pools per NUMA node
- Affinity between feed threads and bus worker threads

#### 8.6 Kernel Bypass NIC (AF_XDP / DPDK)
- **AF_XDP** — Zero-copy packet delivery from NIC to userspace via XDP sockets. Eliminates kernel network stack overhead (~400µs on loopback). Configurable per-feed: standard UDP socket or AF_XDP socket via `FeedConfig.transport` field. Requires BPF program to steer packets to XDP socket.
- **DPDK** — Full kernel bypass with poll-mode drivers for sub-10µs receive latency. Dedicated CPU cores for packet polling (no interrupts). Direct DMA from NIC to application buffers. Requires dedicated NIC and hugepage memory allocation.
- **Configuration** — Runtime transport selection per feed: `.kernel` (default, standard `recvfrom`), `.af_xdp` (zero-copy, requires XDP-capable NIC), `.dpdk` (full bypass, requires dedicated NIC and DPDK drivers). Compile-time protocol parsing is transport-agnostic — same `BinaryProtocol` definitions work regardless of how bytes arrive.
- **Target latency** — AF_XDP: < 5µs receive. DPDK: < 1µs receive. Current kernel UDP: ~50µs receive.

---

### Phase 9: Developer Experience

**Status:** Planned

#### 9.1 REPL / Console
- `zails console` — interactive REPL
- Query models directly
- Test queries in development

#### 9.2 Structured Logging
- JSON-formatted log output
- Query logging with SQL and timings
- Request tracing (distributed tracing support)

#### 9.3 API Documentation
- Auto-generate OpenAPI spec from handlers
- gRPC reflection support
- Interactive API explorer

#### 9.4 Testing Helpers
- Test database setup/teardown
- Factory pattern for test data
- Mock message bus for handler tests
- UDP feed test utilities (send crafted datagrams)

---

### Phase 10: Production Features

**Status:** Planned

#### 10.1 Authentication & Authorization
- JWT token support
- API key authentication
- Role-based access control (RBAC)

#### 10.2 Rate Limiting
- Per-handler rate limits
- Token bucket algorithm
- Redis-backed distributed limits

#### 10.3 Caching Layer
- Query result caching
- Redis integration
- Cache invalidation on model changes / bus events

#### 10.4 Background Jobs
- Job queue (Redis/ClickHouse backed)
- Scheduled jobs (cron-like)
- Job retry logic and status tracking

#### 10.5 Monitoring & Metrics
- Prometheus metrics export
- Health check endpoints
- Custom metrics API
- Feed stats integration

---

### Phase 11: Deployment & Scalability

**Status:** Planned

#### 11.1 Containerization
- Dockerfile with multi-stage build
- Minimal base image (Alpine/scratch)
- Health check endpoints

#### 11.2 Kubernetes Integration
- Helm charts
- Horizontal pod autoscaling
- ConfigMaps for feed/server configuration

#### 11.3 Database Clustering
- ClickHouse cluster support
- Sharding configuration
- Distributed queries

#### 11.4 Zero-Downtime Deployments
- Graceful shutdown (drain connections, stop feeds)
- Rolling updates
- Database migration safety

---

## Completed Features Summary

### Core Framework (100%)
- High-performance TCP server (sub-100µs latency)
- Lock-free object pools
- NUMA-aware worker placement
- Comptime handler dispatch
- Tiger Style error handling
- Convention-based handler auto-discovery

### gRPC Integration (100%)
- Protobuf encoding/decoding
- gRPC service registry (comptime)
- Handler adapter layer
- Status code mapping

### ORM System (100%)
- Query builder with fluent API
- ActiveRecord-like models
- ClickHouse type system
- HTTP client with connection pooling

### Code Generators (100%)
- Model, migration, service, scaffold generators

### Event-Driven Architecture (100%)
- Lock-free message bus with ring buffer
- Pub/sub with topic registry and filtering
- Event workers with async delivery
- Handler integration via globals

### UDP Feed Support (100%)
- Comptime binary protocol generator
- UDP listener with multicast support
- Feed manager with multi-thread lifecycle
- Sequence tracker with gap detection
- Message bus integration

---

## Pending Features Summary

### Advanced ORM (0%)
- Query result parsing, aggregations, joins, validation

### Migration System (0%)
- Migration runner, schema management, diffing, seeds

### Advanced Feed Features (0%)
- Batch receive, protocol expansion, replay/recovery, health monitoring

### Developer Experience (0%)
- REPL, structured logging, API docs, test helpers

### Production Features (0%)
- Auth, rate limiting, caching, background jobs, monitoring

### Deployment (0%)
- Containerization, Kubernetes, clustering, zero-downtime deploys

---

## Timeline & Milestones

### Q1 2026 (Completed)
- gRPC protocol integration
- ClickHouse ORM foundation
- Code generators
- Event-driven architecture (message bus)
- UDP feed support (binary protocols, multicast, feed manager)

### Q2 2026 (In Progress)
- Advanced ORM features (result parsing, aggregations, joins)
- Migration system (runner, schema management)
- Advanced feed features (batch receive, protocol expansion)

### Q3 2026 (Planned)
- Developer experience (REPL, logging, test helpers)
- Production features (auth, rate limiting, caching)

### Q4 2026 (Planned)
- Deployment & scalability
- Performance optimization pass
- Documentation & examples

---

## Success Metrics

### Performance
- P50 latency: 69µs (Target: < 150µs)
- P99 latency: TBD (Target: < 500µs)
- Throughput: 10k+ req/s (Target: 50k+ req/s)
- Success rate: 100%
- UDP parse latency: < 1µs per message

### Code Quality
- Zero unsafe blocks in hot path
- 100% Tiger Style (no throws in handlers)
- 100 tests passing (Target: > 80% coverage)

### Developer Experience
- Code generators reduce boilerplate by 80%
- Time to first API: < 5 minutes
- Time to first feed: < 10 minutes (define protocol + config)

---

## Contributing

### Current Priorities
1. Advanced ORM (query result parsing)
2. Migration runner
3. Feed protocol definitions (MDP3, OUCH, full ITCH 5.0)
4. Batch receive (`recvmmsg`) for high-throughput feeds

### How to Contribute
1. Check the roadmap for pending features
2. Open an issue to discuss implementation
3. Follow Tiger Style conventions
4. Add comprehensive tests
5. Submit PR with benchmarks

---

## Resources

### Documentation
- [Usage Guide](USAGE.md)
- [Contributing Guide](CONTRIBUTING.md)
- [Message Bus User Guide](docs/message_bus/user_guide.md)
- [Message Bus Memory Management](docs/message_bus/memory_management.md)

### Examples
- `src/protocols/example_itch.zig` — Reference ITCH protocol definition
- `handlers/echo_handler.zig` — Basic handler pattern
- `handlers/event_demo_handler.zig` — Message bus integration

---

**Last Updated:** 2026-03-06
**Version:** 0.4.0-alpha
**Status:** Active Development
