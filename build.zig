const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Aeron module (client + logbuffer + ipc + protocol)
    const aeron_mod = b.createModule(.{
        .root_source_file = b.path("src/aeron.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Media driver binary
    const driver_exe = b.addExecutable(.{
        .name = "aeron-driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
            },
        }),
    });
    b.installArtifact(driver_exe);

    const run_cmd = b.addRunArtifact(driver_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the media driver");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/aeron.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_test_step = b.step("test-unit", "Run unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Default test step runs both
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(unit_test_step);
    test_step.dependOn(integration_test_step);

    // Tutorial compile-check
    const chapter = b.option(u32, "chapter", "Active tutorial chapter (default: 0 = compile check only)") orelse 0;
    _ = chapter;
    const tutorial_check = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tutorial/protocol/frame.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const tutorial_check_step = b.step("tutorial-check", "Compile-check tutorial stubs");
    tutorial_check_step.dependOn(&tutorial_check.step);

    // Examples
    const example_files = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "cluster-demo", .path = "examples/cluster_demo.zig" },
        .{ .name = "basic-publisher", .path = "examples/basic_publisher.zig" },
        .{ .name = "basic-subscriber", .path = "examples/basic_subscriber.zig" },
        .{ .name = "throughput-example", .path = "examples/throughput.zig" },
    };
    const examples_step = b.step("examples", "Build all examples");
    for (example_files) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "aeron", .module = aeron_mod },
                },
            }),
        });
        b.installArtifact(exe);
        examples_step.dependOn(&exe.step);
    }
    const demo_step = b.step("demo", "Run cluster demo");
    demo_step.dependOn(examples_step);

    // Fuzz tests
    const fuzz_files = [_][]const u8{
        "src/fuzz/frame.zig",
        "src/fuzz/uri.zig",
        "src/fuzz/ring_buffer.zig",
        "src/fuzz/broadcast.zig",
        "src/fuzz/log_buffer.zig",
        "src/fuzz/catalog.zig",
    };
    const fuzz_step = b.step("fuzz", "Run fuzz tests");
    for (fuzz_files) |fuzz_file| {
        const fuzz_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(fuzz_file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "aeron", .module = aeron_mod },
                },
            }),
        });
        fuzz_step.dependOn(&b.addRunArtifact(fuzz_test).step);
    }

    // Benchmarks
    const bench_files = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "bench-throughput", .path = "src/bench/throughput.zig" },
        .{ .name = "bench-latency", .path = "src/bench/latency.zig" },
        .{ .name = "bench-fanout", .path = "src/bench/fanout.zig" },
    };
    const bench_step = b.step("bench", "Run benchmarks");
    for (bench_files) |bench| {
        const bench_exe = b.addExecutable(.{
            .name = bench.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bench.path),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "aeron", .module = aeron_mod },
                },
            }),
        });
        b.installArtifact(bench_exe);
        bench_step.dependOn(&b.addRunArtifact(bench_exe).step);
    }

    // Stress tests
    const stress_term_rotation = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/stress/term_rotation.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
            },
        }),
    });
    const run_stress_term_rotation = b.addRunArtifact(stress_term_rotation);

    const stress_concurrent_pubs = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/stress/concurrent_pubs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
            },
        }),
    });
    const run_stress_concurrent_pubs = b.addRunArtifact(stress_concurrent_pubs);

    const stress_reconnect = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/stress/reconnect.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
            },
        }),
    });
    const run_stress_reconnect = b.addRunArtifact(stress_reconnect);

    const stress_step = b.step("stress", "Run stress tests");
    stress_step.dependOn(&run_stress_term_rotation.step);
    stress_step.dependOn(&run_stress_concurrent_pubs.step);
    stress_step.dependOn(&run_stress_reconnect.step);
}
