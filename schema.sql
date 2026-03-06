-- ClickHouse Schema for Zails Request Metrics
-- Run this to create the database and table:
-- curl 'http://localhost:8123/' --data-binary @schema.sql

CREATE DATABASE IF NOT EXISTS zails;

CREATE TABLE IF NOT EXISTS zails.zails_request_metrics
(
    -- Timestamp
    timestamp DateTime64(6) DEFAULT now64(),
    date Date DEFAULT toDate(timestamp),

    -- Identity
    request_id UUID,
    message_type UInt8,
    handler_name LowCardinality(String),

    -- Performance Metrics
    latency_us UInt64,
    request_size UInt32,
    response_size UInt32,

    -- Connection Context
    client_ip UInt32,
    client_port UInt16,
    worker_id UInt16,
    server_instance LowCardinality(String),

    -- Error Tracking
    error_code UInt8,
    error_message String,

    -- Debugging (configurable per-handler)
    request_sample String,
    response_sample String,

    -- Indexes for fast queries
    INDEX idx_message_type message_type TYPE minmax GRANULARITY 4,
    INDEX idx_error_code error_code TYPE set(10) GRANULARITY 4
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, timestamp)
TTL date + INTERVAL 30 DAY;

-- Materialized view for handler statistics
CREATE MATERIALIZED VIEW IF NOT EXISTS zails.handler_stats_mv
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, hour, handler_name)
AS SELECT
    date,
    toStartOfHour(timestamp) as hour,
    handler_name,
    message_type,
    count() as request_count,
    sum(latency_us) as total_latency_us,
    quantile(0.50)(latency_us) as p50_latency,
    quantile(0.95)(latency_us) as p95_latency,
    quantile(0.99)(latency_us) as p99_latency,
    max(latency_us) as max_latency,
    sum(request_size) as total_request_bytes,
    sum(response_size) as total_response_bytes,
    sumIf(1, error_code > 0) as error_count
FROM zails.zails_request_metrics
GROUP BY date, hour, handler_name, message_type;

-- Materialized view for error tracking
CREATE MATERIALIZED VIEW IF NOT EXISTS zails.error_tracking_mv
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, hour, error_code, handler_name)
AS SELECT
    date,
    toStartOfHour(timestamp) as hour,
    error_code,
    handler_name,
    error_message,
    count() as error_count
FROM zails.zails_request_metrics
WHERE error_code > 0
GROUP BY date, hour, error_code, handler_name, error_message;

-- Example queries:
--
-- 1. Get latency percentiles by handler (last 24 hours):
-- SELECT
--     handler_name,
--     count() as requests,
--     quantile(0.50)(latency_us) as p50_us,
--     quantile(0.95)(latency_us) as p95_us,
--     quantile(0.99)(latency_us) as p99_us,
--     max(latency_us) as max_us
-- FROM zails.zails_request_metrics
-- WHERE timestamp >= now() - INTERVAL 24 HOUR
-- GROUP BY handler_name
-- ORDER BY requests DESC;
--
-- 2. Error rate by handler (last hour):
-- SELECT
--     handler_name,
--     count() as total_requests,
--     sumIf(1, error_code > 0) as errors,
--     (errors / total_requests) * 100 as error_rate_pct
-- FROM zails.zails_request_metrics
-- WHERE timestamp >= now() - INTERVAL 1 HOUR
-- GROUP BY handler_name
-- ORDER BY error_rate_pct DESC;
--
-- 3. Request throughput over time (per minute):
-- SELECT
--     toStartOfMinute(timestamp) as minute,
--     count() as requests_per_minute
-- FROM zails.zails_request_metrics
-- WHERE timestamp >= now() - INTERVAL 1 HOUR
-- GROUP BY minute
-- ORDER BY minute;
--
-- 4. Top slowest requests (last hour):
-- SELECT
--     timestamp,
--     handler_name,
--     latency_us,
--     request_id,
--     error_code,
--     error_message
-- FROM zails.zails_request_metrics
-- WHERE timestamp >= now() - INTERVAL 1 HOUR
-- ORDER BY latency_us DESC
-- LIMIT 10;
--
-- 5. Worker load distribution:
-- SELECT
--     worker_id,
--     count() as requests,
--     avg(latency_us) as avg_latency_us
-- FROM zails.zails_request_metrics
-- WHERE timestamp >= now() - INTERVAL 1 HOUR
-- GROUP BY worker_id
-- ORDER BY worker_id;
