# Zails Framework Documentation

## For Users

### Message Bus
- **[User Guide](message_bus/user_guide.md)** - How to use the message bus in handlers
- **[Memory Management](message_bus/memory_management.md)** - Event ownership and lifecycle

### Guides
- **[Integrated Handlers](guides/integrated_handlers.md)** - Type-safe reactive models with topic matching

## For Contributors

- **[Contributor Guide](message_bus/contributor_guide.md)** - Architecture, internals, and how to extend the message bus

## Quick Start

```zig
const message_bus = @import("../src/message_bus/mod.zig");

// Subscribe to events
const filter = message_bus.Filter{ .conditions = &.{} };
const sub_id = try bus.subscribe(
    message_bus.ModelTopics("Item").created,
    filter,
    myHandler,
);

// Publish events
message_bus.publishEvent(message_bus.ModelTopics("Item").created, "{\"name\":\"example\"}");
```

See the [User Guide](message_bus/user_guide.md) for complete examples.
