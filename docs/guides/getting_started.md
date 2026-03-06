# Getting Started with Zails

This guide walks you through installing the CLI, creating a new project, adding handlers, and running your server.

## Install the CLI

```bash
# Option 1: Install script (Linux & macOS)
curl -fsSL https://raw.githubusercontent.com/tedkoomen/zails/main/install.sh | sh

# Option 2: Homebrew (macOS)
brew tap tedkoomen/zails
brew install zails

# Option 3: Download from GitHub Releases
# https://github.com/tedkoomen/zails/releases
```

The `zails` binary is self-contained — no dependencies are needed to create projects.

## Prerequisites

To build and run generated projects you need:

- [Zig](https://ziglang.org/download/) (0.15.x)

## Create a New Project

```bash
zails init my-server
cd my-server
```

This creates the following structure:

```
my-server/
├── build.zig           # Build configuration
├── README.md
├── handlers/
│   ├── mod.zig         # Auto-generated handler registry
│   ├── echo_handler.zig
│   └── ping_handler.zig
├── server/             # Framework internals (embedded in the CLI binary)
│   ├── config.zig
│   ├── handler_registry.zig
│   ├── pool_lockfree.zig
│   ├── proto.zig
│   ├── result.zig
│   ├── server_framework.zig
│   └── ...
└── src/
    └── main.zig        # Entry point
```

Two example handlers are included out of the box: `echo_handler` (MESSAGE_TYPE=1) and `ping_handler` (MESSAGE_TYPE=2).

## Build and Run

```bash
zails build
./zig-out/bin/server --ports 8080
```

Test with the built-in client:

```bash
./zig-out/bin/client 8080 1 "Hello, Zails!"
```

The third argument (`1`) is the MESSAGE_TYPE to route to. `1` hits the echo handler, `2` hits the ping handler.

## Adding a Handler

### Option 1: Generator

```bash
zails create handler my_feature
```

This creates `handlers/my_feature.zig` with a unique MESSAGE_TYPE and the required exports pre-filled. Then rebuild:

```bash
zails build
```

### Option 2: By Hand

Create a file in `handlers/` (e.g. `handlers/order_handler.zig`):

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const result = @import("result");

pub const MESSAGE_TYPE: u8 = 10;

pub const Context = struct {
    request_count: std.atomic.Value(u64),

    pub fn init() Context {
        return .{
            .request_count = std.atomic.Value(u64).init(0),
        };
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
    _ = context.request_count.fetchAdd(1, .monotonic);
    _ = allocator;

    const len = @min(request_data.len, response_buffer.len);
    @memcpy(response_buffer[0..len], request_data[0..len]);
    return result.HandlerResponse.ok(response_buffer[0..len]);
}
```

Every handler must export three things:

| Export | Type | Description |
|--------|------|-------------|
| `MESSAGE_TYPE` | `u8` | Unique identifier for routing. Must not conflict with other handlers. |
| `Context` | `struct` | Per-handler state. Must have `init()` and `deinit()`. |
| `handle` | `fn(*Context, []const u8, []u8, Allocator) result.HandlerResponse` | Request handler. Must never throw. |

Then run `zails build` to regenerate `handlers/mod.zig` and compile.

## Creating a gRPC Service

```bash
zails create service UserService
```

This generates `handlers/UserService_handler.zig` with gRPC request/response decoding scaffolded.

## Creating an ORM Model

```bash
zails create model User --table=users
```

This generates `models/User.zig` with field definitions for ClickHouse. Edit the file to define your schema:

```zig
const User = orm.Model("users", .{
    .id = orm.FieldDef{ .type = .UInt64, .primary_key = true },
    .name = orm.FieldDef{ .type = .String },
    .email = orm.FieldDef{ .type = .String },
    .status = orm.FieldDef{ .type = .String, .low_cardinality = true },
});
```

## Creating a Migration

```bash
zails create migration add_users
```

This generates a timestamped SQL file in `migrations/` with UP/DOWN sections.

## Full CRUD Scaffold

Generate a model, migration, and service handler in one command:

```bash
zails scaffold Post --fields=title:String,content:Text
```

This creates:
- `models/Post.zig`
- `migrations/<timestamp>_create_Post.sql`
- `handlers/PostService_handler.zig`

Then run `zails build` to register the new handler.

## Generating Configuration

```bash
zails create config
```

This creates a `config/` directory with:

| File | Purpose |
|------|---------|
| `zails.yaml` | Server settings, handler config, persistence, metrics |
| `alerts.yaml` | Prometheus alert rules |
| `prometheus.yml` | Prometheus scrape config |
| `persistence-examples.yaml` | Database connection examples |

## Handler Rules

These are enforced at compile time:

1. **MESSAGE_TYPE must be unique.** Two handlers claiming the same type is a compile error.
2. **`handle()` must never throw.** Return `result.HandlerResponse.ok(data)` or `result.HandlerResponse.err(error_code)`.
3. **Context must have `init()` and `deinit()`.** These are called once at startup/shutdown, not per-request.
4. **No heap allocations in the hot path.** Use the provided `response_buffer` for output. The `allocator` parameter is available for cases that genuinely need it, but prefer stack and buffer allocation.

## Command Reference

| Command | Description |
|---------|-------------|
| `zails init <name>` | Create a new project |
| `zails build` | Regenerate `handlers/mod.zig` and compile |
| `zails create handler <name>` | Generate a handler |
| `zails create model <name> [--table=...]` | Generate an ORM model |
| `zails create service <name>` | Generate a gRPC service handler |
| `zails create migration <name>` | Generate a database migration |
| `zails create config` | Generate configuration files |
| `zails scaffold <name> [--fields=...]` | Generate model + migration + service |
| `zails help` | Show help |
