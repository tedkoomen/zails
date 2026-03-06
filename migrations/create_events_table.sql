-- Events table for message bus audit log
-- Stores all published events for replay, debugging, and analytics

CREATE TABLE IF NOT EXISTS events (
    -- Event identity
    id UUID DEFAULT generateUUIDv4(),
    timestamp DateTime64(6),
    event_type LowCardinality(String),  -- created, updated, deleted
    topic LowCardinality(String),       -- Trade.created, etc.

    -- Model reference
    model_type LowCardinality(String),  -- Trade, Portfolio, etc.
    model_id UInt64,

    -- Event data (protobuf serialized)
    data String,

    -- Indexes for efficient querying
    PRIMARY KEY (timestamp, id)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, id)
SETTINGS index_granularity = 8192;

-- Materialized view for latest model state
CREATE MATERIALIZED VIEW IF NOT EXISTS events_by_model
ENGINE = AggregatingMergeTree()
ORDER BY (model_type, model_id)
AS SELECT
    model_type,
    model_id,
    maxState(timestamp) as latest_timestamp,
    argMaxState(data, timestamp) as latest_state
FROM events
GROUP BY model_type, model_id;
