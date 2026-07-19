const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Agrona module (shared IPC primitives)
    const agrona_mod = b.addModule("agrona", .{
        .root_source_file = b.path("lib/agrona/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Aeron module (client + logbuffer + ipc + protocol)
    const aeron_mod = b.createModule(.{
        .root_source_file = b.path("src/aeron.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "agrona", .module = agrona_mod },
        },
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
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    driver_exe.root_module.link_libc = true;
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
            .imports = &.{
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    unit_tests.root_module.link_libc = true;
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
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    integration_tests.root_module.link_libc = true;
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Logbuffer tests
    const test_logbuffer = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/logbuffer/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    test_logbuffer.root_module.link_libc = true;
    const run_test_logbuffer = b.addRunArtifact(test_logbuffer);
    const test_logbuffer_step = b.step("test-logbuffer", "Run logbuffer scenario tests");
    test_logbuffer_step.dependOn(&run_test_logbuffer.step);

    // Scenario tests — IPC layer
    const test_ipc = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/ipc/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    test_ipc.root_module.link_libc = true;
    const run_test_ipc = b.addRunArtifact(test_ipc);
    const test_ipc_step = b.step("test-ipc", "Run IPC scenario tests");
    test_ipc_step.dependOn(&run_test_ipc.step);

    // Agrona primitive tests
    const test_agrona = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/agrona/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_agrona.root_module.link_libc = true;
    const run_test_agrona = b.addRunArtifact(test_agrona);
    const test_agrona_step = b.step("test-agrona", "Run Agrona primitive tests");
    test_agrona_step.dependOn(&run_test_agrona.step);

    // Default test step runs all
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(unit_test_step);
    test_step.dependOn(integration_test_step);
    test_step.dependOn(test_logbuffer_step);
    test_step.dependOn(test_ipc_step);
    test_step.dependOn(test_agrona_step);

    // Scenario tests — protocol layer
    const test_protocol = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/protocol/frame_codec_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    test_protocol.root_module.link_libc = true;
    const run_test_protocol = b.addRunArtifact(test_protocol);
    const test_protocol_step = b.step("test-protocol", "Run protocol scenario tests");
    test_protocol_step.dependOn(&run_test_protocol.step);

    // Scenario tests — driver layer
    const test_driver = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/driver/session_establishment_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    test_driver.root_module.link_libc = true;
    const run_test_driver = b.addRunArtifact(test_driver);

    // IPC command dispatch tests — driver layer
    const test_driver_ipc = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/driver/conductor_ipc_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    test_driver_ipc.root_module.link_libc = true;
    const run_test_driver_ipc = b.addRunArtifact(test_driver_ipc);

    // SETUP frame parsing tests — driver layer
    const test_setup_parse = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/driver/setup_frame_parse_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    test_setup_parse.root_module.link_libc = true;
    const run_test_setup_parse = b.addRunArtifact(test_setup_parse);

    // UDP wire and flow-control conformance tests — driver layer
    const test_udp_conformance = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/driver/udp_conformance_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    test_udp_conformance.root_module.link_libc = true;
    const run_test_udp_conformance = b.addRunArtifact(test_udp_conformance);

    // Publication lifecycle tests — driver layer
    const test_pub_lifecycle = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/driver/publication_lifecycle_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    test_pub_lifecycle.root_module.link_libc = true;
    const run_test_pub_lifecycle = b.addRunArtifact(test_pub_lifecycle);

    // Subscription lifecycle tests — driver layer
    const test_sub_lifecycle = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/driver/subscription_lifecycle_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    test_sub_lifecycle.root_module.link_libc = true;
    const run_test_sub_lifecycle = b.addRunArtifact(test_sub_lifecycle);

    const test_driver_step = b.step("test-driver", "Run driver scenario tests");
    test_driver_step.dependOn(&run_test_driver.step);
    test_driver_step.dependOn(&run_test_driver_ipc.step);
    test_driver_step.dependOn(&run_test_setup_parse.step);
    test_driver_step.dependOn(&run_test_udp_conformance.step);
    test_driver_step.dependOn(&run_test_pub_lifecycle.step);
    test_driver_step.dependOn(&run_test_sub_lifecycle.step);

    // Scenario tests — archive layer
    const test_archive = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/archive/catalog_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    test_archive.root_module.link_libc = true;
    const run_test_archive = b.addRunArtifact(test_archive);
    const test_archive_step = b.step("test-archive", "Run archive scenario tests");
    test_archive_step.dependOn(&run_test_archive.step);

    // Scenario tests — cluster layer
    const test_cluster = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/cluster/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    test_cluster.root_module.link_libc = true;
    const run_test_cluster = b.addRunArtifact(test_cluster);
    const test_cluster_step = b.step("test-cluster", "Run cluster scenario tests");
    test_cluster_step.dependOn(&run_test_cluster.step);

    // Scenarios umbrella
    const test_scenarios_step = b.step("test-scenarios", "Run all scenario tests");
    test_scenarios_step.dependOn(test_ipc_step);
    test_scenarios_step.dependOn(test_protocol_step);
    test_scenarios_step.dependOn(test_driver_step);
    test_scenarios_step.dependOn(test_archive_step);
    test_scenarios_step.dependOn(test_cluster_step);

    // Tutorial compile-check
    const tutorial_check = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tutorial/test_all.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const tutorial_check_step = b.step("tutorial-check", "Compile-check tutorial stubs");
    tutorial_check_step.dependOn(&tutorial_check.step);

    // Example behavior tests
    const trading_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/trading_order_book.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "aeron", .module = aeron_mod },
            .{ .name = "agrona", .module = agrona_mod },
        },
    });
    const test_examples = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/examples/trading_order_book_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
                .{ .name = "agrona", .module = agrona_mod },
                .{ .name = "trading", .module = trading_example_mod },
            },
        }),
    });
    test_examples.root_module.link_libc = true;
    const run_test_examples = b.addRunArtifact(test_examples);
    const test_examples_step = b.step("test-examples", "Run example behavior tests");
    test_examples_step.dependOn(&run_test_examples.step);
    test_step.dependOn(test_examples_step);

    // Examples
    const example_files = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "cluster-demo", .path = "examples/cluster_demo.zig" },
        .{ .name = "basic-publisher", .path = "examples/basic_publisher.zig" },
        .{ .name = "basic-subscriber", .path = "examples/basic_subscriber.zig" },
        .{ .name = "throughput-example", .path = "examples/throughput.zig" },
        .{ .name = "trading-order-book", .path = "examples/trading_order_book.zig" },
        .{ .name = "zig-cluster-client", .path = "examples/trading/zig_cluster_client.zig" },
        .{ .name = "zig-cluster-node", .path = "examples/trading/zig_cluster_node.zig" },
        .{ .name = "zig-consensus-member", .path = "examples/trading/zig_consensus_member.zig" },
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
                    .{ .name = "agrona", .module = agrona_mod },
                    .{ .name = "trading", .module = trading_example_mod },
                },
            }),
        });
        exe.root_module.link_libc = true;
        const install_exe = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install_exe.step);
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
                    .{ .name = "agrona", .module = agrona_mod },
                },
            }),
        });
        fuzz_test.root_module.link_libc = true;
        fuzz_step.dependOn(&b.addRunArtifact(fuzz_test).step);
    }

    // Stress tests
    const stress_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/stress/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aeron", .module = aeron_mod },
                .{ .name = "agrona", .module = agrona_mod },
            },
        }),
    });
    stress_tests.root_module.link_libc = true;
    const run_stress_tests = b.addRunArtifact(stress_tests);
    const stress_step = b.step("stress", "Run stress tests");
    stress_step.dependOn(&run_stress_tests.step);

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
                    .{ .name = "agrona", .module = agrona_mod },
                },
            }),
        });
        bench_exe.root_module.link_libc = true;
        b.installArtifact(bench_exe);
        bench_step.dependOn(&b.addRunArtifact(bench_exe).step);
    }
}
