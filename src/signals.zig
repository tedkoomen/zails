const std = @import("std");
const posix = std.posix;

pub const SignalHandler = struct {
    shutdown_flag: *std.atomic.Value(bool),

    pub fn init(shutdown_flag: *std.atomic.Value(bool)) SignalHandler {
        return .{ .shutdown_flag = shutdown_flag };
    }

    pub fn register(self: *SignalHandler) void {
        // Set up signal handlers for graceful shutdown
        const empty_mask = std.mem.zeroes(posix.sigset_t);
        var sa = posix.Sigaction{
            .handler = .{ .handler = handleSignal },
            .mask = empty_mask,
            .flags = 0,
        };

        posix.sigaction(posix.SIG.INT, &sa, null);
        posix.sigaction(posix.SIG.TERM, &sa, null);

        // Store shutdown flag in global storage for signal handler access
        // Signals are process-wide, so thread-local storage is incorrect
        shutdown_ptr = self.shutdown_flag;
    }
};

// Global (not thread-local) because signals can be delivered to any thread
var shutdown_ptr: ?*std.atomic.Value(bool) = null;

fn handleSignal(sig: i32) callconv(.c) void {
    _ = sig;
    // Only set the atomic flag — std.log.info is NOT async-signal-safe
    // and can deadlock if the signal arrives while holding a log mutex.
    // The main loop should check the flag and log the shutdown message.
    if (shutdown_ptr) |ptr| {
        ptr.store(true, .release);
    }
}
