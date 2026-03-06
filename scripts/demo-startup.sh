#!/bin/bash
# Demo: Automatic ClickHouse startup when configured

echo "=== Zerver Auto-Start Demo ==="
echo ""
echo "This demo shows how the server automatically starts ClickHouse"
echo "when it's enabled in the configuration."
echo ""

# Check current config
if grep -A20 "^persistence:" config/zerver.yaml | grep -A15 "clickhouse:" | grep -q "enabled: true"; then
    echo "✓ ClickHouse is ENABLED in config/zerver.yaml"
    echo "  The startup script will automatically:"
    echo "    1. Start ClickHouse Docker container (if not running)"
    echo "    2. Initialize database schema"
    echo "    3. Start the Zerver server"
    echo ""
    echo "To start:"
    echo "  ./scripts/start-server.sh --ports 8080"
else
    echo "✗ ClickHouse is DISABLED in config/zerver.yaml"
    echo ""
    echo "To enable automatic ClickHouse startup:"
    echo "  1. Edit config/zerver.yaml"
    echo "  2. Set persistence.clickhouse.enabled: true"
    echo "  3. Run: ./scripts/start-server.sh --ports 8080"
fi

echo ""
echo "Manual options:"
echo "  Start with ClickHouse:    ./scripts/start-server.sh --ports 8080"
echo "  Start without ClickHouse: ./scripts/start-server.sh --ports 8080 --skip-clickhouse"
echo "  Direct server start:      ./zig-out/bin/server --ports 8080"
echo ""
