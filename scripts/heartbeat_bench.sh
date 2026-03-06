#!/bin/bash

echo "=== Heartbeat Performance Test ==="
echo ""

# Warmup
echo "Warming up..."
for i in {1..100}; do
    ./zig-out/bin/client 8080 2 >/dev/null 2>&1
done

echo "Running heartbeat performance tests..."
echo ""

# Test 1: Single client throughput
echo "Test 1: Single Client Sequential Requests"
start=$(date +%s%N)
for i in {1..1000}; do
    ./zig-out/bin/client 8080 2 >/dev/null 2>&1
done
end=$(date +%s%N)
duration=$(( (end - start) / 1000000 ))
throughput=$(echo "scale=2; 1000 / ($duration / 1000)" | bc)
echo "  1000 requests in ${duration}ms"
echo "  Throughput: ${throughput} req/s"
echo "  Avg latency: $(echo "scale=2; $duration / 1000" | bc)ms"
echo ""

# Test 2: Burst test with parallel clients
echo "Test 2: Parallel Clients (10 clients, 100 requests each)"
start=$(date +%s%N)
for i in {1..10}; do
    (
        for j in {1..100}; do
            ./zig-out/bin/client 8080 2 >/dev/null 2>&1
        done
    ) &
done
wait
end=$(date +%s%N)
duration=$(( (end - start) / 1000000 ))
throughput=$(echo "scale=2; 1000 / ($duration / 1000)" | bc)
echo "  1000 requests in ${duration}ms"
echo "  Throughput: ${throughput} req/s"
echo "  Avg latency per request: $(echo "scale=2; $duration / 1000" | bc)ms"
echo ""

# Test 3: High concurrency
echo "Test 3: High Concurrency (50 clients, 100 requests each)"
start=$(date +%s%N)
for i in {1..50}; do
    (
        for j in {1..100}; do
            ./zig-out/bin/client 8080 2 >/dev/null 2>&1
        done
    ) &
done
wait
end=$(date +%s%N)
duration=$(( (end - start) / 1000000 ))
throughput=$(echo "scale=2; 5000 / ($duration / 1000)" | bc)
echo "  5000 requests in ${duration}ms"
echo "  Throughput: ${throughput} req/s"
echo "  Avg latency per request: $(echo "scale=2; $duration / 5000" | bc)ms"
echo ""

echo "=== Heartbeat Performance Test Complete ==="
