/// Global runtime context shared across modules.
/// Consolidates all global state into a single struct.

const config_system = @import("config_system.zig");
const metrics_mod = @import("metrics.zig");
const async_clickhouse = @import("async_clickhouse.zig");
const message_bus_mod = @import("message_bus/mod.zig");

/// Consolidated runtime context — set by main.zig during initialization.
pub const RuntimeContext = struct {
    runtime_controller: ?*config_system.RuntimeController = null,
    metrics: ?*metrics_mod.MetricsRegistry = null,
    clickhouse: ?*async_clickhouse.AsyncClickHouseWriter = null,
    message_bus: ?*message_bus_mod.MessageBus = null,
    feed_manager: ?*anyopaque = null, // Type-erased (FeedManager is generic)
};

pub var ctx: RuntimeContext = .{};

// Legacy accessors — kept for backward compatibility with existing code.
// New code should use globals.ctx.* directly.
pub var global_runtime_controller: ?*config_system.RuntimeController = null;
pub var global_metrics: ?*metrics_mod.MetricsRegistry = null;
pub var global_clickhouse: ?*async_clickhouse.AsyncClickHouseWriter = null;
pub var global_message_bus: ?*message_bus_mod.MessageBus = null;
pub var global_feed_manager: ?*anyopaque = null;
