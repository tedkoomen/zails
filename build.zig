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
    const client_module = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });

    const client_exe = b.addExecutable(.{
        .name = "client",
        .root_module = client_module,
    });

    b.installArtifact(client_exe);

    const client_run_cmd = b.addRunArtifact(client_exe);
    client_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        client_run_cmd.addArgs(args);
    }

    const client_run_step = b.step("run-client", "Run the client");
    client_run_step.dependOn(&client_run_cmd.step);

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
        .root_source_file = b.path("src/test_message_bus.zig"),
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

    // Zerver CLI tool
    const zerver_module = b.createModule(.{
        .root_source_file = b.path("src/zerver.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zerver_exe = b.addExecutable(.{
        .name = "zerver",
        .root_module = zerver_module,
    });

    b.installArtifact(zerver_exe);

    const zerver_run_cmd = b.addRunArtifact(zerver_exe);
    zerver_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        zerver_run_cmd.addArgs(args);
    }

    const zerver_run_step = b.step("zerver", "Run the zerver CLI");
    zerver_run_step.dependOn(&zerver_run_cmd.step);

    // Test harness for load testing
    const test_harness_module = b.createModule(.{
        .root_source_file = b.path("src/test_harness.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_harness_exe = b.addExecutable(.{
        .name = "test_harness",
        .root_module = test_harness_module,
    });

    b.installArtifact(test_harness_exe);

    const test_harness_run_cmd = b.addRunArtifact(test_harness_exe);
    test_harness_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        test_harness_run_cmd.addArgs(args);
    }

    const test_harness_run_step = b.step("load-test", "Run load tests");
    test_harness_run_step.dependOn(&test_harness_run_cmd.step);

    // Heartbeat benchmark
    const heartbeat_benchmark_module = b.createModule(.{
        .root_source_file = b.path("src/heartbeat_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });

    const heartbeat_benchmark_exe = b.addExecutable(.{
        .name = "heartbeat_benchmark",
        .root_module = heartbeat_benchmark_module,
    });

    b.installArtifact(heartbeat_benchmark_exe);

    const heartbeat_benchmark_run_cmd = b.addRunArtifact(heartbeat_benchmark_exe);
    heartbeat_benchmark_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        heartbeat_benchmark_run_cmd.addArgs(args);
    }

    const heartbeat_benchmark_run_step = b.step("heartbeat-bench", "Run heartbeat performance benchmark");
    heartbeat_benchmark_run_step.dependOn(&heartbeat_benchmark_run_cmd.step);

    // Message Bus Benchmark
    const message_bus_benchmark_module = b.createModule(.{
        .root_source_file = b.path("src/message_bus_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });

    const message_bus_benchmark_exe = b.addExecutable(.{
        .name = "message_bus_benchmark",
        .root_module = message_bus_benchmark_module,
    });

    b.installArtifact(message_bus_benchmark_exe);

    const message_bus_benchmark_run_cmd = b.addRunArtifact(message_bus_benchmark_exe);
    message_bus_benchmark_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        message_bus_benchmark_run_cmd.addArgs(args);
    }

    const message_bus_benchmark_run_step = b.step("message-bus-bench", "Run message bus benchmark");
    message_bus_benchmark_run_step.dependOn(&message_bus_benchmark_run_cmd.step);

    // Integration Test (TCP → Handler → Message Bus → Subscriber)
    const integration_test_module = b.createModule(.{
        .root_source_file = b.path("src/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const integration_test_exe = b.addExecutable(.{
        .name = "integration_test",
        .root_module = integration_test_module,
    });

    b.installArtifact(integration_test_exe);

    const integration_test_run_cmd = b.addRunArtifact(integration_test_exe);
    integration_test_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        integration_test_run_cmd.addArgs(args);
    }

    const integration_test_run_step = b.step("integration-test", "Run integration tests");
    integration_test_run_step.dependOn(&integration_test_run_cmd.step);
}
