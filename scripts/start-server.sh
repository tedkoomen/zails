#!/bin/bash
# Zerver Server Startup Script
# Automatically starts ClickHouse if configured, then starts the server

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_ROOT}/config/zerver.yaml"
SERVER_BIN="${PROJECT_ROOT}/zig-out/bin/server"

echo "=== Zerver Server Startup ==="
echo "Project root: $PROJECT_ROOT"
echo ""

# Check if server binary exists
if [ ! -f "$SERVER_BIN" ]; then
    echo "✗ Server binary not found: $SERVER_BIN"
    echo "Run 'zig build' first"
    exit 1
fi

# Check if config file exists and ClickHouse is enabled
CLICKHOUSE_ENABLED=false
if [ -f "$CONFIG_FILE" ]; then
    # Parse YAML to check if ClickHouse is enabled
    # Simple grep-based parsing (works for basic YAML)
    if grep -A20 "^persistence:" "$CONFIG_FILE" | grep -A15 "clickhouse:" | grep -q "enabled: true"; then
        CLICKHOUSE_ENABLED=true
        echo "ClickHouse is enabled in config"
    fi
fi

# Parse arguments and filter out --skip-clickhouse
SKIP_CLICKHOUSE=false
SERVER_ARGS=()

for arg in "$@"; do
    if [ "$arg" = "--skip-clickhouse" ]; then
        SKIP_CLICKHOUSE=true
    else
        SERVER_ARGS+=("$arg")
    fi
done

# Start ClickHouse if enabled (unless --skip-clickhouse flag is set)
if [ "$CLICKHOUSE_ENABLED" = true ] && [ "$SKIP_CLICKHOUSE" = false ]; then
    echo ""
    if [ -f "${SCRIPT_DIR}/start-clickhouse.sh" ]; then
        cd "$PROJECT_ROOT"  # Run from project root for schema.sql
        if ! "${SCRIPT_DIR}/start-clickhouse.sh"; then
            echo ""
            echo "✗ Failed to start ClickHouse"
            echo "  Server will start anyway, but metrics won't be recorded"
            echo "  To skip ClickHouse startup, use: $0 --skip-clickhouse"
            echo ""
            sleep 2
        fi
    else
        echo "⚠ Warning: start-clickhouse.sh not found, skipping ClickHouse startup"
    fi
    echo ""
elif [ "$SKIP_CLICKHOUSE" = true ]; then
    echo "Skipping ClickHouse startup (--skip-clickhouse flag)"
    echo ""
fi

# Start the server
echo "=== Starting Zerver Server ==="
cd "$PROJECT_ROOT"

# Pass filtered arguments to the server (without --skip-clickhouse)
exec "$SERVER_BIN" "${SERVER_ARGS[@]}"
