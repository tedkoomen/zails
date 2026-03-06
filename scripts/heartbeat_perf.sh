#!/bin/bash

echo "=== Heartbeat (Ping) Performance Test ==="
echo ""
echo "Server: localhost:8080"
echo "Message Type: 2 (Ping/Pong)"
echo ""

# Test 1: Measure average latency
echo "Test 1: Average Latency (100 sequential requests)"
total_time=0
success=0
for i in {1..100}; do
    output=$(./zig-out/bin/client 8080 2 2>&1)
    if echo "$output" | grep -q "RTT:"; then
        rtt=$(echo "$output" | grep "RTT:" | awk '{print $3}' | sed 's/ms//')
        total_time=$(echo "$total_time + $rtt" | bc)
        success=$((success + 1))
    fi
done
avg=$(echo "scale=3; $total_time / $success" | bc)
echo "  Successful requests: $success/100"
echo "  Average RTT: ${avg}ms"
echo ""

# Test 2: Throughput test
echo "Test 2: Sequential Throughput (500 requests)"
start=$(date +%s%N)
count=0
for i in {1..500}; do
    ./zig-out/bin/client 8080 2 >/dev/null 2>&1 && count=$((count + 1))
done
end=$(date +%s%N)
duration_ms=$(echo "scale=2; ($end - $start) / 1000000" | bc)
throughput=$(echo "scale=2; $count / ($duration_ms / 1000)" | bc)
echo "  Successful requests: $count/500"
echo "  Total time: ${duration_ms}ms"
echo "  Throughput: ${throughput} req/s"
echo "  Average latency: $(echo "scale=3; $duration_ms / $count" | bc)ms per request"
echo ""

echo "=== Performance Test Complete ==="
