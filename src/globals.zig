/// Global state shared across modules
/// This avoids circular dependencies in the module system

const config_system = @import("config_system.zig");
const metrics_mod = @import("metrics.zig");
const async_clickhouse = @import("async_clickhouse.zig");
const message_bus_mod = @import("message_bus/mod.zig");

/// Global runtime controller for metrics and profiling
/// Set by main.zig during initialization
pub var global_runtime_controller: ?*config_system.RuntimeController = null;

/// Global metrics registry
/// Set by main.zig during initialization
pub var global_metrics: ?*metrics_mod.MetricsRegistry = null;

/// Global ClickHouse writer for request metrics
/// Set by main.zig during initialization
pub var global_clickhouse: ?*async_clickhouse.AsyncClickHouseWriter = null;

/// Global message bus for event-driven architecture
/// Set by main.zig during initialization
pub var global_message_bus: ?*message_bus_mod.MessageBus = null;

/// Global feed manager for UDP exchange feeds
/// Type-erased because FeedManager is parameterized by comptime protocol tuple
/// Set by main.zig during initialization
pub var global_feed_manager: ?*anyopaque = null;
