/// System-level topics that don't belong to any model.
///
/// These are one-off topics for infrastructure events like
/// server startup, shutdown, and health checks.

pub const SystemTopics = struct {
    pub const startup = "System.startup";
    pub const shutdown = "System.shutdown";
    pub const health_check = "System.health_check";
    pub const wildcard = "System.*";
};
