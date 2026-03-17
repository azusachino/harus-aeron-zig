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
}
