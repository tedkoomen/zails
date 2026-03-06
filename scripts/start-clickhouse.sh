#!/bin/bash
# Start ClickHouse container and initialize schema
# This script is called automatically by the server if ClickHouse is enabled

set -e

CONTAINER_NAME="zails-clickhouse"
CLICKHOUSE_PORT="8123"
CLICKHOUSE_NATIVE_PORT="9000"
SCHEMA_FILE="schema.sql"

echo "=== ClickHouse Startup Script ==="

# Check if ClickHouse container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    # Container exists - check if it's running
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "✓ ClickHouse container already running"
    else
        echo "Starting existing ClickHouse container..."
        docker start ${CONTAINER_NAME}
        sleep 3
        echo "✓ ClickHouse container started"
    fi
else
    # Container doesn't exist - create and start it
    echo "Creating new ClickHouse container..."
    if ! docker run -d \
        --name ${CONTAINER_NAME} \
        -p ${CLICKHOUSE_PORT}:8123 \
        -p ${CLICKHOUSE_NATIVE_PORT}:9000 \
        --ulimit nofile=262144:262144 \
        clickhouse/clickhouse-server; then
        echo "✗ ERROR: Failed to create ClickHouse container"
        echo "  This may be due to:"
        echo "  - Network timeout pulling the image"
        echo "  - Docker daemon issues"
        echo "  - Port conflicts"
        echo ""
        echo "To start without ClickHouse, run:"
        echo "  ./zig-out/bin/server --ports <port>"
        echo ""
        echo "Or disable ClickHouse in config/zails.yaml"
        exit 1
    fi

    echo "Waiting for ClickHouse to be ready..."
    sleep 5

    # Wait for ClickHouse to accept connections
    for i in {1..30}; do
        if curl -s "http://localhost:${CLICKHOUSE_PORT}/" > /dev/null 2>&1; then
            echo "✓ ClickHouse is ready"
            break
        fi
        echo "Waiting... ($i/30)"
        sleep 1
    done
fi

# Check if ClickHouse is responding
if ! curl -s "http://localhost:${CLICKHOUSE_PORT}/" > /dev/null 2>&1; then
    echo "✗ ERROR: ClickHouse is not responding"
    exit 1
fi

# Initialize schema if needed
if [ -f "$SCHEMA_FILE" ]; then
    echo "Initializing ClickHouse schema..."

    # Check if database exists
    DB_EXISTS=$(curl -s "http://localhost:${CLICKHOUSE_PORT}/?query=SHOW+DATABASES" | grep -c "^zails$" || true)

    if [ "$DB_EXISTS" -eq "0" ]; then
        echo "Creating database and tables..."
        curl -s "http://localhost:${CLICKHOUSE_PORT}/" --data-binary @"$SCHEMA_FILE"
        echo "✓ Schema initialized"
    else
        echo "✓ Database already exists"
    fi
else
    echo "⚠ Warning: schema.sql not found, skipping initialization"
fi

# Verify setup
echo ""
echo "=== ClickHouse Status ==="
echo "Container: ${CONTAINER_NAME}"
echo "HTTP Port: ${CLICKHOUSE_PORT}"
echo "Native Port: ${CLICKHOUSE_NATIVE_PORT}"

# Show database info
DB_COUNT=$(curl -s "http://localhost:${CLICKHOUSE_PORT}/?query=SELECT+count()+FROM+system.databases+WHERE+name='zails'" 2>/dev/null || echo "0")
if [ "$DB_COUNT" -eq "1" ]; then
    TABLE_COUNT=$(curl -s "http://localhost:${CLICKHOUSE_PORT}/?query=SELECT+count()+FROM+system.tables+WHERE+database='zails'" 2>/dev/null || echo "0")
    echo "Database: zails (${TABLE_COUNT} tables)"
else
    echo "Database: Not initialized"
fi

echo ""
echo "✓ ClickHouse ready for connections"
