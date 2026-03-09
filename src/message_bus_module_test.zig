// Standalone test entry point for the message_bus module.
//
// Files in src/message_bus/ import ../event.zig, which requires
// the module root to be src/ (not src/message_bus/).
//
// Run with: zig build test-message-bus
//       or: zig test src/message_bus_module_test.zig

test {
    _ = @import("message_bus/mod.zig");
}
