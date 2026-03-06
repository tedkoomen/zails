/// Sequence Tracker - Gap Detection for Exchange Feeds
///
/// Exchange feeds have sequence numbers. Detecting gaps is critical
/// for ensuring no market data messages are missed.
///
/// Lock-free: uses atomic operations only (no mutexes).

const std = @import("std");

pub const SequenceTracker = struct {
    expected_seq: std.atomic.Value(u64),
    gaps_detected: std.atomic.Value(u64),
    duplicates: std.atomic.Value(u64),
    total_checked: std.atomic.Value(u64),

    pub const SeqStatus = union(enum) {
        ok,
        gap: struct { expected: u64, received: u64 },
        duplicate,
    };

    pub fn init(start: u64) SequenceTracker {
        return .{
            .expected_seq = std.atomic.Value(u64).init(start),
            .gaps_detected = std.atomic.Value(u64).init(0),
            .duplicates = std.atomic.Value(u64).init(0),
            .total_checked = std.atomic.Value(u64).init(0),
        };
    }

    /// Check a sequence number against expected.
    /// Updates internal state and returns gap/duplicate/ok status.
    pub fn check(self: *SequenceTracker, seq: u64) SeqStatus {
        _ = self.total_checked.fetchAdd(1, .monotonic);

        const expected = self.expected_seq.load(.acquire);

        if (seq == expected) {
            // Happy path: in order
            self.expected_seq.store(expected + 1, .release);
            return .ok;
        } else if (seq > expected) {
            // Gap detected: missed messages between expected and seq
            _ = self.gaps_detected.fetchAdd(1, .monotonic);
            // Advance past the gap
            self.expected_seq.store(seq + 1, .release);
            return .{ .gap = .{ .expected = expected, .received = seq } };
        } else {
            // seq < expected: duplicate or out-of-order
            _ = self.duplicates.fetchAdd(1, .monotonic);
            return .duplicate;
        }
    }

    /// Reset the tracker to a new starting sequence
    pub fn reset(self: *SequenceTracker, start: u64) void {
        self.expected_seq.store(start, .release);
        self.gaps_detected.store(0, .release);
        self.duplicates.store(0, .release);
        self.total_checked.store(0, .release);
    }

    /// Get current stats
    pub fn getStats(self: *const SequenceTracker) Stats {
        return .{
            .expected_seq = self.expected_seq.load(.acquire),
            .gaps_detected = self.gaps_detected.load(.acquire),
            .duplicates = self.duplicates.load(.acquire),
            .total_checked = self.total_checked.load(.acquire),
        };
    }

    pub const Stats = struct {
        expected_seq: u64,
        gaps_detected: u64,
        duplicates: u64,
        total_checked: u64,
    };
};

// ====================
// Tests
// ====================

test "SequenceTracker in-order sequence" {
    var tracker = SequenceTracker.init(1);

    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(1));
    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(2));
    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(3));

    const stats = tracker.getStats();
    try std.testing.expectEqual(@as(u64, 4), stats.expected_seq);
    try std.testing.expectEqual(@as(u64, 0), stats.gaps_detected);
    try std.testing.expectEqual(@as(u64, 0), stats.duplicates);
    try std.testing.expectEqual(@as(u64, 3), stats.total_checked);
}

test "SequenceTracker gap detection" {
    var tracker = SequenceTracker.init(1);

    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(1));

    // Skip seq 2, jump to 5
    const gap_status = tracker.check(5);
    switch (gap_status) {
        .gap => |g| {
            try std.testing.expectEqual(@as(u64, 2), g.expected);
            try std.testing.expectEqual(@as(u64, 5), g.received);
        },
        else => return error.TestUnexpectedResult,
    }

    const stats = tracker.getStats();
    try std.testing.expectEqual(@as(u64, 6), stats.expected_seq);
    try std.testing.expectEqual(@as(u64, 1), stats.gaps_detected);
}

test "SequenceTracker duplicate detection" {
    var tracker = SequenceTracker.init(1);

    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(1));
    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(2));

    // Duplicate: seq 1 again
    try std.testing.expectEqual(SequenceTracker.SeqStatus.duplicate, tracker.check(1));

    const stats = tracker.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.duplicates);
}

test "SequenceTracker reset" {
    var tracker = SequenceTracker.init(1);

    _ = tracker.check(1);
    _ = tracker.check(5); // gap
    _ = tracker.check(1); // duplicate

    tracker.reset(100);

    const stats = tracker.getStats();
    try std.testing.expectEqual(@as(u64, 100), stats.expected_seq);
    try std.testing.expectEqual(@as(u64, 0), stats.gaps_detected);
    try std.testing.expectEqual(@as(u64, 0), stats.duplicates);
    try std.testing.expectEqual(@as(u64, 0), stats.total_checked);
}

test "SequenceTracker starting at zero" {
    var tracker = SequenceTracker.init(0);

    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(0));
    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(1));
}

test "SequenceTracker multiple gaps" {
    var tracker = SequenceTracker.init(1);

    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(1));

    // Gap 1: skip 2-4
    _ = tracker.check(5);
    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(6));

    // Gap 2: skip 7-9
    _ = tracker.check(10);

    const stats = tracker.getStats();
    try std.testing.expectEqual(@as(u64, 2), stats.gaps_detected);
}

test "SequenceTracker large gap" {
    var tracker = SequenceTracker.init(1);

    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(1));

    // Large gap: skip to 1000001
    const gap_status = tracker.check(1_000_001);
    switch (gap_status) {
        .gap => |g| {
            try std.testing.expectEqual(@as(u64, 2), g.expected);
            try std.testing.expectEqual(@as(u64, 1_000_001), g.received);
        },
        else => return error.TestUnexpectedResult,
    }

    // Next in-order should be 1000002
    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(1_000_002));
}

test "SequenceTracker gap then duplicate of gap range" {
    var tracker = SequenceTracker.init(1);

    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(1));
    // Gap: skip 2-4, jump to 5
    _ = tracker.check(5);

    // Now receiving the missed messages (2,3,4) — should be duplicate since we advanced past them
    try std.testing.expectEqual(SequenceTracker.SeqStatus.duplicate, tracker.check(2));
    try std.testing.expectEqual(SequenceTracker.SeqStatus.duplicate, tracker.check(3));
    try std.testing.expectEqual(SequenceTracker.SeqStatus.duplicate, tracker.check(4));

    const stats = tracker.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.gaps_detected);
    try std.testing.expectEqual(@as(u64, 3), stats.duplicates);
    try std.testing.expectEqual(@as(u64, 5), stats.total_checked);
}

test "SequenceTracker high starting sequence" {
    var tracker = SequenceTracker.init(std.math.maxInt(u64) - 5);

    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(std.math.maxInt(u64) - 5));
    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(std.math.maxInt(u64) - 4));
    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(std.math.maxInt(u64) - 3));

    const stats = tracker.getStats();
    try std.testing.expectEqual(@as(u64, 3), stats.total_checked);
    try std.testing.expectEqual(@as(u64, 0), stats.gaps_detected);
}

test "SequenceTracker getStats is consistent" {
    var tracker = SequenceTracker.init(10);

    // 10 ok, 11 ok, gap to 15, 15 ok, dup 10, dup 11
    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(10));
    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(11));
    _ = tracker.check(15); // gap
    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(16));
    try std.testing.expectEqual(SequenceTracker.SeqStatus.duplicate, tracker.check(10));
    try std.testing.expectEqual(SequenceTracker.SeqStatus.duplicate, tracker.check(11));

    const stats = tracker.getStats();
    try std.testing.expectEqual(@as(u64, 17), stats.expected_seq);
    try std.testing.expectEqual(@as(u64, 1), stats.gaps_detected);
    try std.testing.expectEqual(@as(u64, 2), stats.duplicates);
    try std.testing.expectEqual(@as(u64, 6), stats.total_checked);
}

test "SequenceTracker reset then resume" {
    var tracker = SequenceTracker.init(1);

    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(1));
    _ = tracker.check(5); // gap

    // Reset to a new sequence range
    tracker.reset(100);

    // Old sequence values are now duplicates relative to 100
    try std.testing.expectEqual(SequenceTracker.SeqStatus.duplicate, tracker.check(5));

    // New sequence range works
    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(100));
    try std.testing.expectEqual(SequenceTracker.SeqStatus.ok, tracker.check(101));

    const stats = tracker.getStats();
    try std.testing.expectEqual(@as(u64, 102), stats.expected_seq);
    // Stats were reset, so only counts from after reset
    try std.testing.expectEqual(@as(u64, 0), stats.gaps_detected);
    try std.testing.expectEqual(@as(u64, 1), stats.duplicates);
    try std.testing.expectEqual(@as(u64, 3), stats.total_checked);
}

test "SequenceTracker concurrent access" {
    var tracker = SequenceTracker.init(0);

    // Spawn multiple threads that concurrently call check()
    const num_threads = 4;
    const checks_per_thread = 1000;

    var threads: [num_threads]std.Thread = undefined;
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn worker(t: *SequenceTracker, thread_id: usize) void {
                for (0..checks_per_thread) |j| {
                    // Each thread checks unique sequence numbers to avoid
                    // deterministic ordering assumptions
                    const seq = thread_id * checks_per_thread + j;
                    _ = t.check(seq);
                }
            }
        }.worker, .{ &tracker, i });
    }

    for (&threads) |thread| {
        thread.join();
    }

    // All checks should have been counted
    const stats = tracker.getStats();
    try std.testing.expectEqual(@as(u64, num_threads * checks_per_thread), stats.total_checked);
    // Gaps + duplicates + ok should equal total_checked
    // (we can't predict exact gap/dup counts due to thread interleaving,
    // but total_checked must be exact)
}
