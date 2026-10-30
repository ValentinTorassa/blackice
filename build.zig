const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "blackice",
        .root_module = root,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run blackice");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    if (target.result.os.tag == .linux) {
        const helper_root = b.createModule(.{
            .root_source_file = b.path("src/linux/helper.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .strip = true,
        });
        const helper = b.addExecutable(.{ .name = "blackice-linux-helper", .root_module = helper_root });
        b.installArtifact(helper);
        const helper_tests = b.addTest(.{ .root_module = helper_root });
        test_step.dependOn(&b.addRunArtifact(helper_tests).step);

        const probe_root = b.createModule(.{
            .root_source_file = b.path("src/linux/probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "blackice_core", .module = root }},
        });
        const probe = b.addExecutable(.{ .name = "blackice-linux-probe", .root_module = probe_root });
        const probe_step = b.step("linux-probe", "Build the explicit Linux backend test harness");
        probe_step.dependOn(&b.addInstallArtifact(probe, .{}).step);
        const probe_tests = b.addTest(.{ .root_module = probe_root });
        test_step.dependOn(&b.addRunArtifact(probe_tests).step);
    }
}
