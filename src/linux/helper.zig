//! Installed static capability helper. Never accepts an arbitrary PID or a command to run privileged.
const std = @import("std");
const sys = @import("sys.zig");
const l = sys.l;
const wire = @import("protocol.zig");
const cgroup = @import("cgroup.zig");
const filter = @import("filter.zig");
const confinement = @import("confinement.zig");

// A capability-bearing binary must never open source files or symbolize a same-uid injected signal.
pub const std_options: std.Options = .{ .enable_segfault_handler = false };
pub const panic = std.debug.FullPanic(fatalPanic);
fn fatalPanic(_: []const u8, _: ?usize) noreturn {
    sys.writeAll(2, "blackice Linux helper: internal failure; policy retained\n") catch {};
    l.exit_group(125);
}

const Output = struct {
    lost: u64 = 0,
    fn send(o: *Output, event: wire.Event, required: bool) !void {
        const bytes = std.mem.asBytes(&event);
        for (0..30) |_| {
            const rc = l.write(3, bytes.ptr, bytes.len);
            switch (l.errno(rc)) {
                .SUCCESS => {
                    if (rc != bytes.len) return error.InvalidProtocol;
                    return;
                },
                .INTR => continue,
                .AGAIN => {
                    if (!required) {
                        o.lost += 1;
                        return;
                    }
                    var fds = [_]l.pollfd{.{ .fd = 3, .events = l.POLL.OUT, .revents = 0 }};
                    _ = try sys.poll(&fds, 100);
                },
                else => return error.ReceiptPipeClosed,
            }
        }
        return error.ReceiptWriterStalled;
    }
};

pub fn main(init: std.process.Init) u8 {
    var out: Output = .{};
    var stage: []const u8 = "arguments";
    run(init, &out, &stage) catch |err| {
        var buf: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}: {s}", .{ stage, @errorName(err) }) catch @errorName(err);
        out.send(wire.Event.init(.failure, msg), true) catch {};
        sys.writeAll(2, "blackice Linux helper: ") catch {};
        sys.writeAll(2, msg) catch {};
        sys.writeAll(2, "\n") catch {};
        return 125;
    };
    return 0;
}

fn run(init: std.process.Init, out: *Output, stage: *[]const u8) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 8 or !std.mem.eql(u8, args[1], wire.launch_version) or !wire.validScope(args[2])) return error.HelperProtocolV2Required;
    if (!wire.validPath(args[4])) return error.InvalidStateDirectory;
    const protected_count = try wire.parseProtectedCount(args[5]);
    if (protected_count > wire.max_protected or args.len < protected_count + 8 or !std.mem.eql(u8, args[6 + protected_count], "--")) return error.InvalidArguments;
    var protected_buf: [wire.max_protected][:0]const u8 = undefined;
    for (args[6..][0..protected_count], 0..) |path, i| {
        if (!wire.validPath(path)) return error.InvalidProtectedPath;
        protected_buf[i] = try gpa.dupeSentinel(u8, path, 0);
    }
    const protected = protected_buf[0..protected_count];
    const command = args[7 + protected_count ..];
    const state = try gpa.dupeSentinel(u8, args[4], 0);
    var ports_buf: [wire.max_ports]u16 = undefined;
    const ports = try wire.parsePorts(args[3], &ports_buf);
    stage.* = "helper_privileges";
    if (l.getuid() == 0 or l.geteuid() != l.getuid()) return error.UnprivilegedCallerRequired;
    try sys.requireCapabilities();
    try sys.nonDumpable();
    try sys.ensureStdio();
    if ((try sys.stat(3)).mode & 0o170000 != 0o010000) return error.ReceiptPipeRequired;
    const flags = try sys.check(l.fcntl(3, l.F.GETFL, 0));
    _ = try sys.check(l.fcntl(3, l.F.SETFL, flags | @as(u32, @bitCast(l.O{ .NONBLOCK = true }))));
    // Ignore SIGPIPE via the blocked mask; parent death is observed by pidfd.
    var mask: l.sigset_t = std.mem.zeroes(l.sigset_t);
    for ([_]l.SIG{ .INT, .TERM, .HUP, .PIPE }) |sig| {
        const bit: usize = @backingInt(sig) - 1;
        mask[bit / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(bit % @bitSizeOf(usize));
    }
    _ = try sys.check(l.sigprocmask(l.SIG.BLOCK, &mask, null));
    const signals = try sys.fd(l.signalfd(-1, &mask, l.SFD.CLOEXEC | l.SFD.NONBLOCK));
    defer sys.close(signals);
    const parent = l.getppid();
    if (parent <= 1) return error.ParentMissing;
    const parentfd = try sys.fd(l.pidfd_open(parent, 0));
    defer sys.close(parentfd);
    if (l.getppid() != parent) return error.ParentMissing;

    stage.* = "host_namespaces";
    try cgroup.requireHostNamespaces();
    stage.* = "root_cgroup";
    var scope = try cgroup.Scope.create(args[2]);
    defer scope.close();
    errdefer scope.cleanup() catch {
        out.send(wire.Event.init(.failure, "cleanup_failed_policy_retained; owner recovery required"), true) catch {};
    };
    stage.* = "kernel_filter";
    var rules = try filter.Filter.create();
    defer rules.close();
    var verifier: [32768]u8 = @splat(0);
    rules.arm(scope.dir, ports, &verifier) catch |err| {
        sys.writeAll(2, std.mem.sliceTo(&verifier, 0)) catch {};
        return err;
    };
    var ring = try filter.Ring.open(rules.ring_fd);
    defer ring.close();

    // All allocation and PATH resolution precedes fork; child uses only stack storage and syscalls.
    const argv = try makeArgv(gpa, command);
    const env = try init.environ_map.createPosixBlock(gpa, .{ .zig_progress_fd = -1 });
    const exe = try resolve(gpa, command[0], init.environ_map.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin");
    const gate = try sys.pipe();
    defer sys.close(gate[1]);
    const report = try sys.pipe();
    defer sys.close(report[0]);
    const helper_pid = l.getpid();
    const uid = l.getuid();
    const gid = l.getgid();
    stage.* = "paused_child";
    const child: l.pid_t = @intCast(try sys.check(l.fork()));
    if (child == 0) childMain(gate, report, helper_pid, uid, gid, state, protected, exe, argv, env.slice);
    sys.close(gate[0]);
    sys.close(report[1]);
    var reaped = false;
    defer if (!reaped) {
        _ = l.kill(child, .KILL);
        _ = sys.wait(child) catch 0;
    };
    const childfd = try sys.fd(l.pidfd_open(child, 0));
    defer sys.close(childfd);
    stage.* = "enrollment";
    try scope.enroll(child);
    try sys.writeAll(gate[1], "A");
    stage.* = "child_user_namespace";
    if (try childReady(report[0], parentfd, out) != 'U') return error.ChildContainmentFailed;
    // The child stays non-dumpable. Its proc mapping files therefore need our existing DAC capability.
    stage.* = "child_id_mapping";
    try confinement.mapChild(child, uid, gid);
    try sys.writeAll(gate[1], "M");
    stage.* = "child_containment";
    if (try childReady(report[0], parentfd, out) != 'R') return error.ChildContainmentFailed;
    try out.send(wire.Event.init(.armed, "cgroup_sock_addr; landlock_abi6; seccomp; protected_paths; private_mounts"), true);
    stage.* = "exec";
    try sys.writeAll(gate[1], "G");
    // report[1] is CLOEXEC: EOF acknowledges successful exec; an error writes E instead.
    var ready = [_]l.pollfd{ .{ .fd = report[0], .events = l.POLL.IN, .revents = 0 }, .{ .fd = parentfd, .events = l.POLL.IN, .revents = 0 } };
    var ack: [1]u8 = undefined;
    if (try sys.poll(&ready, 10000) == 0 or ready[1].revents != 0) return error.ExecTimeout;
    if (try sys.read(report[0], &ack) != 0) return error.CommandExecFailed;
    stage.* = "running";
    var cancelled = false;
    while (true) {
        try drain(out, &ring);
        var fds = [_]l.pollfd{
            .{ .fd = childfd, .events = l.POLL.IN, .revents = 0 },
            .{ .fd = parentfd, .events = l.POLL.IN, .revents = 0 },
            .{ .fd = signals, .events = l.POLL.IN, .revents = 0 },
            .{ .fd = rules.ring_fd, .events = l.POLL.IN, .revents = 0 },
        };
        _ = try sys.poll(&fds, 100);
        if (fds[1].revents != 0 or fds[2].revents != 0) {
            cancelled = true;
            break;
        }
        if (fds[0].revents != 0) break;
    }
    stage.* = "scope_cleanup";
    try scope.cleanup(); // terminate descendants before releasing the scope's policy
    const status = try sys.wait(child);
    reaped = true;
    try drain(out, &ring);
    const lost = (try rules.loss()) + out.lost;
    if (lost > 0) {
        var event = wire.Event.init(.loss, "kernel_ring_or_receipt_pipe_overflow");
        event.value = lost;
        try out.send(event, true);
    }
    try out.send(wire.Event.init(.cleanup, "cgroup_empty_and_removed"), true);
    var event = wire.Event.init(if (l.W.IFEXITED(status)) .exited else .signaled, if (cancelled) "scope_cancelled" else "command_finished");
    event.value = if (l.W.IFEXITED(status)) l.W.EXITSTATUS(status) else @backingInt(l.W.TERMSIG(status));
    try out.send(event, true);
}

fn childReady(report: l.fd_t, parent: l.fd_t, out: *Output) !u8 {
    var ready = [_]l.pollfd{ .{ .fd = report, .events = l.POLL.IN, .revents = 0 }, .{ .fd = parent, .events = l.POLL.IN, .revents = 0 } };
    if (try sys.poll(&ready, 10000) == 0 or ready[1].revents != 0) return error.LaunchTimeout;
    var ack: [1]u8 = undefined;
    if (try sys.read(report, &ack) != 1) return error.ChildContainmentFailed;
    if (ack[0] == 'E') {
        var detail: [80]u8 = undefined;
        if (try sys.readFull(report, &detail)) try out.send(wire.Event.init(.failure, std.mem.sliceTo(&detail, 0)), true);
        return error.ChildContainmentFailed;
    }
    return ack[0];
}

fn childMain(gate: [2]l.fd_t, report: [2]l.fd_t, parent: l.pid_t, uid: u32, gid: u32, state: [:0]const u8, protected: []const [:0]const u8, exe: [:0]const u8, argv: [:null]?[*:0]const u8, env: [:null]const ?[*:0]const u8) noreturn {
    sys.close(gate[1]);
    sys.close(report[0]);
    childSetup(gate[0], report[1], parent, uid, gid, state, protected) catch |err| {
        var report_error: [81]u8 = @splat(0);
        report_error[0] = 'E';
        const name = @errorName(err);
        @memcpy(report_error[1..][0..@min(name.len, 79)], name[0..@min(name.len, 79)]);
        sys.writeAll(5, &report_error) catch {};
        sys.writeAll(2, "blackice child containment: ") catch {};
        sys.writeAll(2, name) catch {};
        sys.writeAll(2, "\n") catch {};
        l.exit_group(125);
    };
    _ = l.execve(exe, argv, env);
    sys.writeAll(5, "E") catch {};
    l.exit_group(127);
}

fn childSetup(gate: l.fd_t, report: l.fd_t, parent: l.pid_t, uid: u32, gid: u32, state: [:0]const u8, protected: []const [:0]const u8) !void {
    // Close every fd except stdio and the two handshake pipes, including the receipt writer and BPF maps.
    // dup3 is collision-free because both original pipes are >= 4 and copied above the reserved descriptors.
    const gate_copy = try sys.fd(l.fcntl(gate, l.F.DUPFD_CLOEXEC, 100));
    const report_copy = try sys.fd(l.fcntl(report, l.F.DUPFD_CLOEXEC, 100));
    _ = try sys.check(l.dup3(gate_copy, 4, @bitCast(l.O{ .CLOEXEC = true })));
    _ = try sys.check(l.dup3(report_copy, 5, @bitCast(l.O{ .CLOEXEC = true })));
    sys.close(3);
    _ = try sys.check(l.close_range(6, std.math.maxInt(i32), .{ .UNSHARE = false, .CLOEXEC = false }));
    var empty: l.sigset_t = std.mem.zeroes(l.sigset_t);
    _ = try sys.check(l.sigprocmask(l.SIG.SETMASK, &empty, null));
    var ack: [1]u8 = undefined;
    if (!try sys.readFull(4, &ack) or ack[0] != 'A') return error.EnrollmentMissing;
    try confinement.createNamespaces();
    try sys.writeAll(5, "U");
    if (!try sys.readFull(4, &ack) or ack[0] != 'M') return error.NamespaceMappingMissing;
    if (l.getuid() != uid or l.getgid() != gid) return error.NamespaceMappingMismatch;
    try confinement.armMapped(state, protected);
    _ = try sys.check(l.prctl(@backingInt(l.PR.SET_PDEATHSIG), @backingInt(l.SIG.KILL), 0, 0, 0));
    if (l.getppid() != parent) return error.ParentMissing;
    try sys.writeAll(5, "R");
    if (!try sys.readFull(4, &ack) or ack[0] != 'G') return error.ActivationMissing;
    sys.close(4);
    // fd 5 remains CLOEXEC for the exec acknowledgement; no trusted descriptor reaches the command.
}

fn drain(out: *Output, ring: *filter.Ring) !void {
    for (0..2048) |_| {
        const d = try ring.next() orelse break;
        var event = wire.Event.init(.drop, "cgroup_socket_admission_denied");
        event.value = d.hook;
        event.ip = d.ip;
        event.port = std.mem.bigToNative(u16, @truncate(d.port));
        event.family = @intCast(d.family);
        event.protocol = d.protocol;
        event.pid = @truncate(d.pid_tgid >> 32);
        try out.send(event, false);
    }
}

pub fn makeArgv(gpa: std.mem.Allocator, args: []const []const u8) ![:null]?[*:0]const u8 {
    const argv = try gpa.allocSentinel(?[*:0]const u8, args.len, null);
    for (args, 0..) |a, i| {
        if (std.mem.findScalar(u8, a, 0) != null) return error.InvalidArguments;
        argv[i] = (try gpa.dupeSentinel(u8, a, 0)).ptr;
    }
    return argv;
}

fn resolve(gpa: std.mem.Allocator, command: []const u8, path: []const u8) ![:0]const u8 {
    if (command.len == 0) return error.CommandMissing;
    if (std.mem.findScalar(u8, command, '/') != null) return gpa.dupeSentinel(u8, command, 0);
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const candidate = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ if (dir.len > 0) dir else ".", command }, 0);
        if (l.errno(l.faccessat(l.AT.FDCWD, candidate, 1, 0)) == .SUCCESS) return candidate;
    }
    return error.CommandMissing;
}

test {
    _ = wire;
    _ = filter;
    _ = confinement;
}
