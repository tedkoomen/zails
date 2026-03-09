# Zails Framework - Build, Test, and Flamegraph Analysis
#
# Build:
#   docker build -t zails .
#
# Run tests:
#   docker run --rm zails test
#   docker run --rm zails test-simulation
#   docker run --rm zails test-simulation-fast    # ReleaseFast
#
# Run benchmarks:
#   docker run --rm zails bench-message-bus --mode filter-micro --events 10000000
#   docker run --rm zails bench-heartbeat
#
# Generate flamegraph (requires --privileged for perf):
#   docker run --rm --privileged -v $(pwd)/flamegraphs:/out zails flamegraph message_bus_benchmark --mode throughput --duration 5
#   docker run --rm --privileged -v $(pwd)/flamegraphs:/out zails flamegraph server --ports 8080
#
# Interactive shell:
#   docker run --rm -it zails shell

FROM debian:bookworm-slim AS base

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    xz-utils \
    ca-certificates \
    linux-perf \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.15.0 (latest stable compatible with codebase)
ARG ZIG_VERSION=0.15.0
RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
        amd64) ZIG_ARCH=x86_64 ;; \
        arm64) ZIG_ARCH=aarch64 ;; \
        *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz" \
        | tar -xJ -C /opt && \
    ln -s /opt/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}/zig /usr/local/bin/zig

# Install FlameGraph tools
RUN git clone --depth 1 https://github.com/brendangregg/FlameGraph.git /opt/FlameGraph

ENV PATH="/opt/FlameGraph:${PATH}"

WORKDIR /app

# Copy source
COPY . .

# Build all targets in ReleaseFast for benchmarks
RUN zig build -Doptimize=ReleaseFast 2>/dev/null || true

# Also build debug for tests
RUN zig build 2>/dev/null || true

# Create output directory for flamegraphs
RUN mkdir -p /out

# Entrypoint script
COPY <<'ENTRYPOINT_SCRIPT' /usr/local/bin/entrypoint.sh
#!/bin/bash
set -e

case "${1:-help}" in
    test)
        shift
        echo "=== Running unit tests ==="
        zig build test -- "$@"
        ;;

    test-simulation)
        shift
        echo "=== Running simulation tests ==="
        zig build test-simulation -- "$@"
        ;;

    test-simulation-fast)
        shift
        echo "=== Running simulation tests (ReleaseFast) ==="
        zig build test-simulation -Doptimize=ReleaseFast -- "$@"
        ;;

    test-message-bus)
        shift
        echo "=== Running message bus tests ==="
        zig build test-message-bus -- "$@"
        ;;

    bench-message-bus)
        shift
        echo "=== Running message bus benchmark ==="
        zig build -Doptimize=ReleaseFast 2>/dev/null
        ./zig-out/bin/message_bus_benchmark "$@"
        ;;

    bench-heartbeat)
        shift
        echo "=== Running heartbeat benchmark ==="
        zig build -Doptimize=ReleaseFast 2>/dev/null
        ./zig-out/bin/heartbeat_benchmark "$@"
        ;;

    flamegraph)
        shift
        BINARY="${1:?Usage: flamegraph <binary> [args...]}"
        shift

        # Build ReleaseFast with debug info
        echo "=== Building $BINARY (ReleaseFast) ==="
        zig build -Doptimize=ReleaseFast 2>/dev/null

        BINARY_PATH="./zig-out/bin/$BINARY"
        if [ ! -f "$BINARY_PATH" ]; then
            echo "Error: binary not found: $BINARY_PATH"
            echo "Available binaries:"
            ls ./zig-out/bin/ 2>/dev/null || echo "  (none built)"
            exit 1
        fi

        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        PERF_DATA="/tmp/perf_${BINARY}_${TIMESTAMP}.data"
        SVG_OUT="/out/${BINARY}_${TIMESTAMP}.svg"

        echo "=== Recording perf data for: $BINARY_PATH $* ==="
        echo "    (will record for duration of program, or Ctrl+C to stop)"

        # Record with perf (requires --privileged)
        perf record -F 99 -g --call-graph dwarf -o "$PERF_DATA" -- "$BINARY_PATH" "$@" || true

        echo "=== Generating flamegraph ==="
        perf script -i "$PERF_DATA" \
            | stackcollapse-perf.pl \
            | flamegraph.pl --title "$BINARY flamegraph" --width 1800 \
            > "$SVG_OUT"

        echo "=== Flamegraph written to: $SVG_OUT ==="
        echo "    Mount /out to access: -v \$(pwd)/flamegraphs:/out"

        # Also generate a reverse flamegraph (icicle)
        ICICLE_OUT="/out/${BINARY}_${TIMESTAMP}_icicle.svg"
        perf script -i "$PERF_DATA" \
            | stackcollapse-perf.pl \
            | flamegraph.pl --title "$BINARY icicle" --width 1800 --reverse --inverted \
            > "$ICICLE_OUT"

        echo "=== Icicle graph written to: $ICICLE_OUT ==="

        # Cleanup
        rm -f "$PERF_DATA"
        ;;

    build)
        shift
        echo "=== Building ==="
        zig build "$@"
        ;;

    shell)
        exec /bin/bash
        ;;

    help|--help|-h)
        cat <<EOF
Zails Docker Commands:

  test                          Run unit tests
  test-simulation               Run deterministic simulation tests
  test-simulation-fast          Run simulation tests (ReleaseFast)
  test-message-bus              Run message bus module tests
  bench-message-bus [args]      Run message bus benchmark
  bench-heartbeat               Run heartbeat benchmark
  flamegraph <binary> [args]    Record perf + generate flamegraph SVG
  build [args]                  Build with custom args
  shell                         Interactive bash shell

Flamegraph examples:
  docker run --rm --privileged -v \$(pwd)/flamegraphs:/out zails \\
    flamegraph message_bus_benchmark --mode throughput --duration 5

  docker run --rm --privileged -v \$(pwd)/flamegraphs:/out zails \\
    flamegraph message_bus_benchmark --mode filter-micro --events 10000000
EOF
        ;;

    *)
        echo "Unknown command: $1 (try 'help')"
        exit 1
        ;;
esac
ENTRYPOINT_SCRIPT

RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["help"]
