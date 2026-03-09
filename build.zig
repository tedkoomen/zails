const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create shared result module (used by both root and handlers)
    const result_module = b.createModule(.{
        .root_source_file = b.path("src/result.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create handlers module
    const handlers_module = b.createModule(.{
        .root_source_file = b.path("handlers/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    handlers_module.addImport("result", result_module);

    // Create root module with handlers import
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("handlers", handlers_module);
    root_module.addImport("result", result_module);

    // Main server executable
    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // Client executable
    _ = addClientExe(b, "src/client.zig", target, optimize);

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Add same imports as root module
    test_module.addImport("handlers", handlers_module);
    test_module.addImport("result", result_module);

    const unit_tests = b.addTest(.{
        .name = "tests",
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Message bus module tests (standalone)
    const message_bus_test_module = b.createModule(.{
        .root_source_file = b.path("src/message_bus_module_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const message_bus_tests = b.addTest(.{
        .name = "message_bus_tests",
        .root_module = message_bus_test_module,
    });

    const run_message_bus_tests = b.addRunArtifact(message_bus_tests);
    const message_bus_test_step = b.step("test-message-bus", "Run message bus module tests (including event_builder)");
    message_bus_test_step.dependOn(&run_message_bus_tests.step);

    // Zails CLI tool
    const zails_module = b.createModule(.{
        .root_source_file = b.path("src/zails.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zails_exe = b.addExecutable(.{
        .name = "zails",
        .root_module = zails_module,
    });

    b.installArtifact(zails_exe);

    // Build only the CLI (for cross-platform releases)
    const cli_step = b.step("cli", "Build only the zails CLI");
    cli_step.dependOn(&b.addInstallArtifact(zails_exe, .{}).step);

    const zails_run_cmd = b.addRunArtifact(zails_exe);
    zails_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        zails_run_cmd.addArgs(args);
    }

    const zails_run_step = b.step("zails", "Run the zails CLI");
    zails_run_step.dependOn(&zails_run_cmd.step);

    // Test harness for load testing
    _ = addExeWithRunStep(b, "test_harness", "src/test_harness.zig", "load-test", "Run load tests", target, optimize);

    // Heartbeat benchmark
    _ = addExeWithRunStep(b, "heartbeat_benchmark", "src/heartbeat_benchmark.zig", "heartbeat-bench", "Run heartbeat performance benchmark", target, optimize);

    // Message Bus Benchmark
    _ = addExeWithRunStep(b, "message_bus_benchmark", "src/message_bus_benchmark.zig", "message-bus-bench", "Run message bus benchmark", target, optimize);

    // Integration Test (TCP → Handler → Message Bus → Subscriber)
    _ = addExeWithRunStep(b, "integration_test", "src/integration_test.zig", "integration-test", "Run integration tests", target, optimize);

    // Deterministic Simulation Tests (TigerBeetle-inspired)
    const sim_test_module = b.createModule(.{
        .root_source_file = b.path("src/simulation_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sim_tests = b.addTest(.{
        .name = "simulation_tests",
        .root_module = sim_test_module,
    });

    const run_sim_tests = b.addRunArtifact(sim_tests);
    const sim_test_step = b.step("test-simulation", "Run deterministic simulation tests");
    sim_test_step.dependOn(&run_sim_tests.step);
}

/// Helper to create an executable with an associated run step.
/// Used for standalone tools/benchmarks that don't need extra module imports.
fn addExeWithRunStep(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    step_name: []const u8,
    description: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step(step_name, description);
    run_step.dependOn(&run_cmd.step);

    return exe;
}

/// Helper for client executable with run step (same pattern but also used
/// for the client binary).
fn addClientExe(
    b: *std.Build,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return addExeWithRunStep(b, "client", source, "run-client", "Run the client", target, optimize);
}
