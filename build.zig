const std = @import("std");

/// The targets of `zig build release`. Linux binaries are static (std only, no libc); macOS binaries link only
/// libSystem.
const release_targets = [_][]const u8{ "x86_64-linux", "aarch64-linux", "aarch64-macos", "x86_64-macos" };

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
        // Match linux-build-helper.sh even when the main executable targets the native CPU.
        const helper_target = b.resolveTargetQuery(.{
            .cpu_arch = target.result.cpu.arch,
            .cpu_model = .baseline,
            .os_tag = .linux,
        });
        const helper_root = b.createModule(.{
            .root_source_file = b.path("src/linux/helper.zig"),
            .target = helper_target,
            .optimize = .ReleaseSafe,
            .strip = true,
        });
        const helper = b.addExecutable(.{ .name = "blackice-linux-helper", .root_module = helper_root });
        b.installArtifact(helper);
        const helper_tests = b.addTest(.{ .root_module = helper_root });
        test_step.dependOn(&b.addRunArtifact(helper_tests).step);

        const launch_io_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/linux/launch_io.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(launch_io_tests).step);

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

    // Separate, opt-in build: never loads or attaches anything.
    const apps_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .cpu_model = .baseline, .os_tag = .linux });
    const apps_root = b.createModule(.{ .root_source_file = b.path("src/linux_appfilter.zig"), .target = apps_target, .optimize = .ReleaseSafe, .strip = true });
    const apps = b.addExecutable(.{ .name = "blackice-linux-appfilter", .root_module = apps_root });
    b.step("linux-appfilter", "Build the kernel-pinned Linux application filter (no install to host)").dependOn(&b.addInstallArtifact(apps, .{}).step);
    const apps_tests = b.addTest(.{ .root_module = apps_root, .filters = &.{"appfilter"} });
    const apps_test_step = b.step("linux-appfilter-test", "Run pure application-filter and CLI unit tests; no BPF or network activity");
    apps_test_step.dependOn(&b.addRunArtifact(apps_tests).step);
    const apps_cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/linux_appfilter_cli_test.zig"),
            .target = apps_target,
            .optimize = .ReleaseSafe,
        }),
        // Imported sys.zig also has a socket/fork fixture; it is not part of this pure test step.
        .filters = &.{"appfilter"},
    });
    apps_test_step.dependOn(&b.addRunArtifact(apps_cli_tests).step);

    addRelease(b);
}

/// `zig build release`: every release target, ReleaseSafe and stripped, as zig-out/release/blackice-<target>.
/// Stripping drops the debug info, which holds absolute build paths, so the same commit built with the same Zig
/// gives the same bytes in any directory. Cross targets never use the build host's CPU features.
/// -Dmacos-min sets the oldest macOS the binaries start on; without it Zig would write its own default (15.0).
/// It also decides which system interfaces the standard library may use, so test with the same minimum.
fn addRelease(b: *std.Build) void {
    const macos_min = b.option([]const u8, "macos-min", "Oldest macOS the release binaries run on (default 13.0)") orelse "13.0";
    const release_step = b.step("release", "Build stripped, reproducible binaries for every release target");
    for (release_targets) |name| {
        const triple = if (std.mem.endsWith(u8, name, "-macos")) b.fmt("{s}.{s}", .{ name, macos_min }) else name;
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch |err| {
            // Only the release step fails; the other steps still work with a bad -Dmacos-min.
            const fail = b.addFail(b.fmt("release target {s}: {s} (check -Dmacos-min)", .{ triple, @errorName(err) }));
            release_step.dependOn(&fail.step);
            continue;
        };
        const exe = b.addExecutable(.{
            .name = "blackice",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(query),
                .optimize = .ReleaseSafe,
                .strip = true,
            }),
        });
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
            .dest_sub_path = b.fmt("blackice-{s}", .{name}),
        });
        release_step.dependOn(&install.step);
    }
}
