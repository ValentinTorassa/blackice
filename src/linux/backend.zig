//! Linux task scopes: kernel admission and a single receipt writer in the blackice process.
const std = @import("std");
const backend = @import("../core/backend.zig");
const sys = @import("sys.zig");
const l = sys.l;
const wire = @import("protocol.zig");
pub const available = true;
pub fn launch(gpa: std.mem.Allocator, io: std.Io, spec: backend.LaunchSpec) backend.Error!backend.Exit {
    _ = io;
    return launchInner(gpa, spec) catch |err| {
        spec.receipts.write(.{ .event = "warning", .point = .control, .verdict = .deny, .reason = "linux_launch_refused", .detail = @errorName(err) });
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.SpawnFailed;
    };
}

fn launchInner(gpa: std.mem.Allocator, spec: backend.LaunchSpec) !backend.Exit {
    if (!wire.validScope(spec.scope_id) or spec.argv.len == 0 or spec.allowed_loopback_ports.len > wire.max_ports) return error.InvalidLaunchSpec;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ports_buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&ports_buf);
    if (spec.allowed_loopback_ports.len == 0) try writer.writeByte('-');
    for (spec.allowed_loopback_ports, 0..) |port, i| {
        if (port == 0) return error.InvalidLaunchSpec;
        for (spec.allowed_loopback_ports[0..i]) |prior| if (prior == port) return error.InvalidLaunchSpec;
        if (i > 0) try writer.writeByte(',');
        try writer.print("{d}", .{port});
    }
    const state = spec.state_dir;
    if (state.len < 2 or state[0] != '/' or std.mem.findScalar(u8, state, 0) != null) return error.InvalidStateDirectory;
    const args = try alloc.alloc(?[*:0]const u8, spec.argv.len + 7);
    const prefix = [_][]const u8{ wire.helper_path, "--protocol-v1", spec.scope_id, writer.buffered(), state, "--" };
    for (prefix, 0..) |a, i| args[i] = (try alloc.dupeSentinel(u8, a, 0)).ptr;
    for (spec.argv, 6..) |a, i| {
        if (std.mem.findScalar(u8, a, 0) != null) return error.InvalidLaunchSpec;
        args[i] = (try alloc.dupeSentinel(u8, a, 0)).ptr;
    }
    args[args.len - 1] = null;
    const env = try spec.environ.createPosixBlock(alloc, .{ .zig_progress_fd = -1 });
    try sys.ensureStdio();
    const executable = sys.fd(l.open(wire.helper_path, .{ .CLOEXEC = true, .NOFOLLOW = true }, 0)) catch {
        spec.receipts.write(.{ .event = "warning", .point = .control, .reason = "linux_helper_missing", .detail = "Build helper, then have the owner run scripts/linux-setup.sh; command was not launched" });
        return error.HelperNotInstalled;
    };
    defer sys.close(executable);
    try sys.rootOwned(executable);
    const helper_stat = try sys.stat(executable);
    if (helper_stat.mode & 0o170000 != 0o100000 or helper_stat.mode & 0o111 == 0) return error.InvalidHelperInstallation;
    // A confined child must not ptrace its outside supervisor, proxy or relay.
    try sys.nonDumpable();
    const pipe = try sys.pipe();
    defer sys.close(pipe[0]);
    const pid: l.pid_t = @intCast(try sys.check(l.fork()));
    if (pid == 0) {
        // No allocation or std.Io after fork from a possibly multithreaded core.
        const exec_copy = sys.fd(l.fcntl(executable, l.F.DUPFD_CLOEXEC, 100)) catch l.exit_group(125);
        _ = sys.check(l.dup3(pipe[1], 3, 0)) catch l.exit_group(125);
        _ = sys.check(l.dup3(exec_copy, 4, @bitCast(l.O{ .CLOEXEC = true }))) catch l.exit_group(125);
        _ = sys.check(l.close_range(5, std.math.maxInt(i32), .{ .UNSHARE = false, .CLOEXEC = false })) catch l.exit_group(125);
        _ = l.execveat(4, "", @ptrCast(args.ptr), env.slice, .{ .EMPTY_PATH = true, .SYMLINK_NOFOLLOW = true });
        l.exit_group(125);
    }
    sys.close(pipe[1]);
    var reaped = false;
    defer if (!reaped) {
        // SIGTERM is handled by the helper and kills the entire cgroup. Never detach live policy here.
        _ = l.kill(pid, .TERM);
        _ = sys.wait(pid) catch 0;
    };
    var armed = false;
    var clean = false;
    var failed = false;
    var result: ?backend.Exit = null;
    var event: wire.Event = undefined;
    while (try sys.readFull(pipe[0], std.mem.asBytes(&event))) {
        switch (try event.tag()) {
            .armed => {
                if (armed) return error.InvalidHelperProtocol;
                armed = true;
                spec.receipts.write(.{ .event = "backend_armed", .point = .kernel, .reason = "linux_cgroup_bpf", .detail = event.text() });
            },
            .drop => {
                if (!armed) return error.InvalidHelperProtocol;
                var ip_buf: [64]u8 = undefined;
                const ip = try formatIp(&ip_buf, event.family, event.ip);
                var detail_buf: [100]u8 = undefined;
                const detail = try std.fmt.bufPrint(&detail_buf, "backend=cgroup_sock_addr hook={d} protocol={d} pid={d}", .{ event.value, event.protocol, event.pid });
                spec.receipts.write(.{ .event = "kernel_drop", .point = .kernel, .verdict = .deny, .reason = "loopback_proxy_only", .ip = ip, .port = event.port, .detail = detail });
            },
            .loss => {
                var buf: [128]u8 = undefined;
                const detail = try std.fmt.bufPrint(&buf, "{d} denial receipts lost ({s}); enforcement unchanged", .{ event.value, event.text() });
                spec.receipts.write(.{ .event = "warning", .point = .kernel, .reason = "kernel_receipts_lost", .detail = detail });
            },
            .failure => {
                failed = true;
                spec.receipts.write(.{ .event = "warning", .point = .kernel, .verdict = .deny, .reason = "linux_helper_failure", .detail = event.text() });
            },
            .cleanup => {
                clean = true;
                spec.receipts.write(.{ .event = "backend_cleanup", .point = .kernel, .reason = "cgroup_removed", .detail = event.text() });
            },
            .exited => {
                if (result != null or event.value > 255) return error.InvalidHelperProtocol;
                result = .{ .exited = @intCast(event.value) };
            },
            .signaled => {
                if (result != null or event.value > 64) return error.InvalidHelperProtocol;
                result = .{ .signal = @intCast(event.value) };
            },
        }
    }
    const status = try sys.wait(pid);
    reaped = true;
    if (!l.W.IFEXITED(status) or l.W.EXITSTATUS(status) != 0 or failed or !armed or !clean) return error.HelperFailed;
    return result orelse error.MissingExitReceipt;
}

fn formatIp(buf: []u8, family: u16, ip: [16]u8) ![]const u8 {
    if (family == l.AF.INET) return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
    if (family != l.AF.INET6) return error.InvalidHelperProtocol;
    return std.fmt.bufPrint(buf, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
        std.mem.readInt(u16, ip[0..2], .big),   std.mem.readInt(u16, ip[2..4], .big),
        std.mem.readInt(u16, ip[4..6], .big),   std.mem.readInt(u16, ip[6..8], .big),
        std.mem.readInt(u16, ip[8..10], .big),  std.mem.readInt(u16, ip[10..12], .big),
        std.mem.readInt(u16, ip[12..14], .big), std.mem.readInt(u16, ip[14..16], .big),
    });
}

test "invalid launch cannot execute a command" {
    if (@import("builtin").os.tag != .linux) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var receipts = try @import("../core/receipt.zig").Log.open(std.testing.io, tmp.dir, "refused.jsonl", "bad", "test");
    defer receipts.close();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.SpawnFailed, launch(std.testing.allocator, std.testing.io, .{
        .scope_id = "../../bad",
        .argv = &.{ "/bin/sh", "-c", "exit 99" },
        .environ = &env,
        .allowed_loopback_ports = &.{},
        .state_dir = "/invalid",
        .receipts = &receipts,
    }));
}
