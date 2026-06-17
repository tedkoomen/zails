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

    // Public runtime module for applications that depend on Zails as a library:
    // const zails = @import("zails");
    const runtime_module = b.addModule("zails", .{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_module.addImport("result", result_module);
    b.installFile("include/zails/zails.h", "include/zails/zails.h");
    b.installFile("include/zails/zails.hpp", "include/zails/zails.hpp");

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
    const test_step = b.step("test", "Run unit tests");
    const message_bus_test_step = b.step("test-message-bus", "Run message bus module tests (including event_builder)");
    const sim_test_step = b.step("test-simulation", "Run deterministic simulation tests");
    const cpp_runtime_test_step = b.step("test-cpp-runtime", "Run C++ foreign-worker runtime integration tests");

    if (target.result.os.tag == .linux) {
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
        test_step.dependOn(&run_unit_tests.step);

        const extra_test_files = [_]struct {
            name: []const u8,
            path: []const u8,
            needs_result: bool = false,
        }{
            .{ .name = "config_tests", .path = "src/config.zig" },
            .{ .name = "config_system_tests", .path = "src/config_system.zig" },
            .{ .name = "proto_tests", .path = "src/proto.zig" },
            .{ .name = "event_tests", .path = "src/event.zig" },
            .{ .name = "foreign_handler_tests", .path = "src/foreign_handler.zig", .needs_result = true },
            .{ .name = "runtime_tests", .path = "src/runtime.zig", .needs_result = true },
            .{ .name = "local_ipc_tests", .path = "src/local_ipc.zig" },
            .{ .name = "query_builder_tests", .path = "src/orm/query_builder.zig" },
            .{ .name = "model_tests", .path = "src/orm/model.zig" },
            .{ .name = "field_types_tests", .path = "src/orm/field_types.zig" },
            .{ .name = "binary_protocol_tests", .path = "src/udp/binary_protocol.zig" },
            .{ .name = "sequence_tracker_tests", .path = "src/udp/sequence_tracker.zig" },
            .{ .name = "ring_buffer_tests", .path = "src/test_ring_buffer.zig" },
            .{ .name = "subscriber_registry_tests", .path = "src/test_lockfree_subscriber_registry.zig" },
            .{ .name = "example_handler_tests", .path = "handlers/example_handler.zig", .needs_result = true },
            .{ .name = "metrics_handler_tests", .path = "handlers/metrics_handler.zig", .needs_result = true },
            .{ .name = "subscription_handler_tests", .path = "handlers/subscription_handler.zig", .needs_result = true },
        };

        for (extra_test_files) |test_file| {
            const extra_module = b.createModule(.{
                .root_source_file = b.path(test_file.path),
                .target = target,
                .optimize = optimize,
            });
            if (test_file.needs_result) {
                extra_module.addImport("result", result_module);
            }

            const extra_tests = b.addTest(.{
                .name = test_file.name,
                .root_module = extra_module,
            });
            const run_extra_tests = b.addRunArtifact(extra_tests);
            test_step.dependOn(&run_extra_tests.step);
        }

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
        message_bus_test_step.dependOn(&run_message_bus_tests.step);
        test_step.dependOn(&run_message_bus_tests.step);

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
        sim_test_step.dependOn(&run_sim_tests.step);
        test_step.dependOn(&run_sim_tests.step);

        const cpp_worker_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        cpp_worker_module.addCSourceFile(.{
            .file = b.path("tests/cpp_runtime_worker.cpp"),
            .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-Iinclude" },
        });

        const cpp_worker = b.addExecutable(.{
            .name = "cpp_runtime_worker",
            .root_module = cpp_worker_module,
        });
        const install_cpp_worker = b.addInstallArtifact(cpp_worker, .{});

        const cpp_runtime_options = b.addOptions();
        cpp_runtime_options.addOption([]const u8, "worker_path", b.getInstallPath(.bin, "cpp_runtime_worker"));
        cpp_runtime_options.addOption(u16, "worker_port", 39091);

        const cpp_runtime_test_module = b.createModule(.{
            .root_source_file = b.path("src/cpp_runtime_integration_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        cpp_runtime_test_module.addImport("zails", runtime_module);
        cpp_runtime_test_module.addOptions("cpp_runtime_options", cpp_runtime_options);

        const cpp_runtime_tests = b.addTest(.{
            .name = "cpp_runtime_integration_tests",
            .root_module = cpp_runtime_test_module,
        });
        const run_cpp_runtime_tests = b.addRunArtifact(cpp_runtime_tests);
        run_cpp_runtime_tests.step.dependOn(&install_cpp_worker.step);
        test_step.dependOn(&run_cpp_runtime_tests.step);
        cpp_runtime_test_step.dependOn(&run_cpp_runtime_tests.step);
    }

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

    const runtime_example_module = b.createModule(.{
        .root_source_file = b.path("examples/runtime_app_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_example_module.addImport("zails", runtime_module);

    const runtime_example_exe = b.addExecutable(.{
        .name = "runtime_app_example",
        .root_module = runtime_example_module,
    });

    const runtime_example_step = b.step("runtime-example", "Build the importable runtime app example");
    runtime_example_step.dependOn(&b.addInstallArtifact(runtime_example_exe, .{}).step);

    // Test harness for load testing
    _ = addExeWithRunStep(b, "test_harness", "src/test_harness.zig", "load-test", "Run load tests", target, optimize);

    // Heartbeat benchmark
    _ = addExeWithRunStep(b, "heartbeat_benchmark", "src/heartbeat_benchmark.zig", "heartbeat-bench", "Run heartbeat performance benchmark", target, optimize);

    // Message Bus Benchmark
    _ = addExeWithRunStep(b, "message_bus_benchmark", "src/message_bus_benchmark.zig", "message-bus-bench", "Run message bus benchmark", target, optimize);

    // Allocation probe for valgrind/massif validation of hot paths.
    _ = addExeWithRunStep(b, "allocation_probe", "src/allocation_probe.zig", "allocation-probe", "Run allocation probe", target, optimize);

    // Integration Test (TCP → Handler → Message Bus → Subscriber)
    _ = addExeWithRunStep(b, "integration_test", "src/integration_test.zig", "integration-test", "Run integration tests", target, optimize);
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
