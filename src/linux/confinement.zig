//! Mandatory child-side IPC/namespace boundary. All operations finish before exec.
const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const l = sys.l;

pub fn namespaces(uid: u32, gid: u32, state: [:0]const u8) !void {
    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try sys.check(l.getcwd(&cwd_buf, cwd_buf.len));
    if (cwd_len < 2) return error.WorkingDirectoryUnavailable;
    const cwd = cwd_buf[0 .. cwd_len - 1 :0];
    var temporary_root: ?[]const u8 = null;
    for ([_][]const u8{ "/tmp", "/var/tmp" }) |root| {
        // Restoring a whole temporary root would expose unrelated daemon paths again.
        if (std.mem.eql(u8, cwd, root)) return error.WorkingDirectoryAtTemporaryRoot;
        if (std.mem.startsWith(u8, cwd, root) and cwd.len > root.len and cwd[root.len] == '/') temporary_root = root;
    }
    try sys.dropCapabilities();
    // Retain the caller's numeric IDs. Only this uid/gid is mapped in the private user namespace.
    _ = try sys.check(l.unshare(l.CLONE.NEWUSER | l.CLONE.NEWNS));
    var buf: [80]u8 = undefined;
    try sys.writeFileAt(l.AT.FDCWD, "/proc/self/setgroups", "deny\n");
    try sys.writeFileAt(l.AT.FDCWD, "/proc/self/uid_map", try std.fmt.bufPrint(&buf, "{d} {d} 1\n", .{ uid, uid }));
    try sys.writeFileAt(l.AT.FDCWD, "/proc/self/gid_map", try std.fmt.bufPrint(&buf, "{d} {d} 1\n", .{ gid, gid }));
    _ = try sys.check(l.mount(null, "/", null, l.MS.REC | l.MS.PRIVATE, 0));
    // Protect the whole state root, including submounts. An alias through a pre-opened fd is closed
    // by the launch handshake. The broader same-user filesystem/IPC threat remains a declared limit.
    _ = try sys.check(l.mount(state, state, null, l.MS.BIND | l.MS.REC, 0));
    const MountAttr = extern struct { set: u64 = 15, clear: u64 = 0, propagation: u64 = 0, userns: u64 = 0 };
    const attr: MountAttr = .{}; // RDONLY | NOSUID | NODEV | NOEXEC
    _ = try sys.check(l.syscall5(.mount_setattr, @bitCast(@as(isize, l.AT.FDCWD)), @intFromPtr(state.ptr), 0x8000, @intFromPtr(&attr), @sizeOf(MountAttr)));
    // Resolve through the new state mount before pinning the project, so a nested state root stays read-only.
    const project = if (temporary_root != null)
        try sys.fd(l.open(cwd, .{ .PATH = true, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0))
    else
        -1;
    defer if (project >= 0) sys.close(project);
    // /var/run normally points at /run. A separate /var/run is masked as well.
    try maskDir("/run");
    try maskDir("/var/run");
    try maskDir("/tmp");
    try maskDir("/var/tmp");
    if (temporary_root) |root| try restoreProject(project, cwd, root.len);
    // Reopen cwd by path, so an inherited cwd cannot retain a reference into a masked mount.
    _ = try sys.check(l.chdir("/"));
    _ = try sys.check(l.chdir(cwd));
}

fn restoreProject(project: l.fd_t, cwd: [:0]const u8, root_len: usize) !void {
    // These parents exist only in our new private tmpfs. The bind exposes precisely cwd, not its old parent.
    var path: [4096]u8 = undefined;
    @memcpy(path[0..cwd.len], cwd);
    path[cwd.len] = 0;
    for (root_len + 1..cwd.len + 1) |i| {
        if (i != cwd.len and path[i] != '/') continue;
        const saved = path[i];
        path[i] = 0;
        const rc = l.mkdirat(l.AT.FDCWD, @ptrCast(&path), 0o700);
        if (l.errno(rc) != .EXIST) _ = try sys.check(rc);
        path[i] = saved;
    }
    var source_buf: [64]u8 = undefined;
    const source = try std.fmt.bufPrintSentinel(&source_buf, "/proc/self/fd/{d}", .{project}, 0);
    _ = try sys.check(l.mount(source, cwd, null, l.MS.BIND | l.MS.REC, 0));
}

fn maskDir(path: [:0]const u8) !void {
    // No shell, no writable staging mount, and no shared host mount propagation.
    const data: [:0]const u8 = "mode=1777,size=16m";
    _ = try sys.check(l.mount("blackice", path, "tmpfs", l.MS.NOSUID | l.MS.NODEV | l.MS.NOEXEC, @intFromPtr(data.ptr)));
}

pub fn landlock() !void {
    const abi = try sys.check(l.syscall3(.landlock_create_ruleset, 0, 0, 1));
    // ABI 6 adds signal and abstract-Unix scoping. This strict profile requires both.
    if (abi < 6) return error.LandlockAbi6Required;
    const Attr = extern struct { fs: u64 = 0, net: u64 = 0, scoped: u64 = 3 };
    const attr: Attr = .{};
    const rules = try sys.fd(l.syscall3(.landlock_create_ruleset, @intFromPtr(&attr), @sizeOf(Attr), 0));
    defer sys.close(rules);
    try sys.noNewPrivileges();
    _ = try sys.check(l.syscall2(.landlock_restrict_self, @intCast(rules), 0));
}

const Filter = extern struct { code: u16, jt: u8 = 0, jf: u8 = 0, k: u32 };
const Program = extern struct { len: u16, filter: [*]const Filter };
const deny: u32 = l.SECCOMP.RET.ERRNO | @as(u32, @backingInt(l.E.PERM));
const allow = l.SECCOMP.RET.ALLOW;
fn stmt(code: u16, k: u32) Filter {
    return .{ .code = code, .k = k };
}
fn eq(k: u32, jt: u8, jf: u8) Filter {
    return .{ .code = 0x15, .k = k, .jt = jt, .jf = jf };
}
const Builder = struct {
    items: [192]Filter = undefined,
    len: usize = 0,
    fn add(b: *Builder, f: Filter) void {
        b.items[b.len] = f;
        b.len += 1;
    }
    fn refuse(b: *Builder, call: l.SYS, result: u32) void {
        b.add(eq(@intCast(@backingInt(call)), 0, 1));
        b.add(stmt(0x06, result));
    }
};

pub fn filters() Builder {
    var b: Builder = .{};
    const arch: u32 = switch (builtin.cpu.arch) {
        .x86_64 => 0xc000003e,
        .aarch64 => 0xc00000b7,
        else => @compileError("Linux helper supports x86_64 and aarch64 only"),
    };
    b.add(stmt(0x20, 4)); // seccomp_data.arch: reject compat ABI, including int 0x80.
    b.add(eq(arch, 1, 0));
    b.add(stmt(0x06, l.SECCOMP.RET.KILL_PROCESS));
    b.add(stmt(0x20, 0)); // syscall number
    if (builtin.cpu.arch == .x86_64) {
        b.add(.{ .code = 0x45, .k = 0x40000000, .jt = 0, .jf = 1 }); // x32
        b.add(stmt(0x06, l.SECCOMP.RET.KILL_PROCESS));
    }
    const denied = [_]l.SYS{
        .unshare,          .setns,       .mount,          .umount2,        .pivot_root,        .chroot,          .open_tree, .move_mount,
        .fsopen,           .fsmount,     .fspick,         .mount_setattr,  .bpf,               .perf_event_open, .ptrace,    .process_vm_writev,
        .process_vm_readv, .pidfd_getfd, .io_uring_setup, .io_uring_enter, .io_uring_register, .bind,            .listen,    .accept4,
        .userfaultfd,
    };
    for (denied) |call| b.refuse(call, deny);
    // libcs can fall back to clone; seccomp cannot safely dereference clone3's argument struct.
    b.refuse(.clone3, l.SECCOMP.RET.ERRNO | @as(u32, @backingInt(l.E.NOSYS)));
    b.add(eq(@backingInt(l.SYS.clone), 0, 4));
    b.add(stmt(0x20, 16)); // args[0], clone flags
    b.add(.{ .code = 0x45, .k = 0x7e020000, .jt = 0, .jf = 1 }); // namespace flags
    b.add(stmt(0x06, deny));
    b.add(stmt(0x06, allow));
    // SCTP and unconnected ping sockets do not use the same cgroup hooks. Permit only TCP/UDP.
    b.add(eq(@backingInt(l.SYS.socketpair), 0, 4));
    b.add(stmt(0x20, 16));
    b.add(eq(l.AF.UNIX, 1, 0));
    b.add(stmt(0x06, deny));
    b.add(stmt(0x06, allow));
    b.add(eq(@backingInt(l.SYS.socket), 0, 15));
    b.add(stmt(0x20, 16));
    b.add(eq(l.AF.INET, 2, 0));
    b.add(eq(l.AF.INET6, 1, 0));
    b.add(stmt(0x06, deny));
    b.add(stmt(0x20, 24)); // args[1], socket type (strip SOCK_CLOEXEC/NONBLOCK)
    b.add(stmt(0x54, 0xf));
    b.add(eq(l.SOCK.STREAM, 2, 0));
    b.add(eq(l.SOCK.DGRAM, 1, 0));
    b.add(stmt(0x06, deny));
    b.add(stmt(0x20, 32)); // args[2]: default, TCP, UDP only
    b.add(eq(0, 3, 0));
    b.add(eq(6, 2, 0));
    b.add(eq(17, 1, 0));
    b.add(stmt(0x06, deny));
    b.add(stmt(0x06, allow));
    b.add(stmt(0x06, allow));
    return b;
}

pub fn seccomp() !void {
    const b = filters();
    const p: Program = .{ .len = @intCast(b.len), .filter = &b.items };
    try sys.noNewPrivileges();
    _ = try sys.check(l.prctl(@backingInt(l.PR.SET_SECCOMP), l.SECCOMP.MODE.FILTER, @intFromPtr(&p), 0, 0));
}

pub fn arm(uid: u32, gid: u32, state: [:0]const u8) !void {
    try namespaces(uid, gid, state);
    try landlock();
    try sys.dropCapabilities();
    try sys.nonDumpable();
    try seccomp();
}

test "private mounts preserve uid and cwd, hide daemon paths, and protect state before exec" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    path_buf[n] = 0;
    const state = path_buf[0..n :0];
    const file = try tmp.dir.createFile(std.testing.io, "state", .{});
    file.close(std.testing.io);
    const uid = l.getuid();
    const gid = l.getgid();
    const pid: l.pid_t = @intCast(try sys.check(l.fork()));
    if (pid == 0) {
        arm(uid, gid, state) catch |err| {
            sys.writeAll(2, @errorName(err)) catch {};
            l.exit_group(1);
        };
        if (l.getuid() != uid or l.getgid() != gid) l.exit_group(2);
        const state_fd = sys.fd(l.open(state, .{ .DIRECTORY = true, .CLOEXEC = true }, 0)) catch l.exit_group(3);
        if (l.errno(l.openat(state_fd, "state", .{ .ACCMODE = .WRONLY }, 0)) != .ROFS) l.exit_group(4);
        const caps = sys.capabilities() catch l.exit_group(5);
        if (caps[0].effective != 0 or caps[1].effective != 0 or caps[0].permitted != 0 or caps[1].permitted != 0) l.exit_group(6);
        if (l.errno(l.open("/run/dbus/system_bus_socket", .{}, 0)) != .NOENT) l.exit_group(7);
        if (l.errno(l.socket(l.AF.UNIX, l.SOCK.STREAM, 0)) != .PERM) l.exit_group(8);
        if (l.errno(l.kill(l.getppid(), .CONT)) != .PERM) l.exit_group(9);
        l.exit_group(0);
    }
    try std.testing.expectEqual(@as(u32, 0), try sys.wait(pid));
}

test "temporary projects retain cwd and executables without exposing siblings or writable state" {
    for ([_][:0]const u8{ "/tmp", "/var/tmp" }) |root| try testTemporaryProject(root);
}

fn testTemporaryProject(root: [:0]const u8) !void {
    const io = std.testing.io;
    var random: [8]u8 = undefined;
    io.random(&random);
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrintSentinel(&base_buf, "{s}/blackice-test-{s}", .{ root, std.fmt.bytesToHex(random, .lower) }, 0);
    try std.Io.Dir.createDirAbsolute(io, base, .fromMode(0o700));
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    var dir = try std.Io.Dir.openDirAbsolute(io, base, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "parent/project/state/scopes/first");
    try dir.createDirPath(io, "parent/project/state/scopes/second");
    try dir.writeFile(io, .{ .sub_path = "outside", .data = "hidden\n" });
    try dir.writeFile(io, .{ .sub_path = "parent/sibling", .data = "hidden\n" });
    try dir.writeFile(io, .{ .sub_path = "parent/project/payload", .data = "project\n" });
    for ([_][]const u8{ "parent/project/state/scopes/first/receipt", "parent/project/state/scopes/second/receipt" }) |path| {
        try dir.writeFile(io, .{ .sub_path = path, .data = "read-only\n" });
    }
    const script = try dir.createFile(io, "parent/project/project-command", .{ .permissions = .fromMode(0o700) });
    try sys.writeAll(script.handle, "#!/bin/sh\nexit 0\n");
    script.close(io);
    var cwd_buf: [256]u8 = undefined;
    const cwd = try std.fmt.bufPrintSentinel(&cwd_buf, "{s}/parent/project", .{base}, 0);
    var state_buf: [256]u8 = undefined;
    const state = try std.fmt.bufPrintSentinel(&state_buf, "{s}/state", .{cwd}, 0);
    var outside_buf: [256]u8 = undefined;
    const outside = try std.fmt.bufPrintSentinel(&outside_buf, "{s}/outside", .{base}, 0);
    const uid = l.getuid();
    const gid = l.getgid();
    const pid: l.pid_t = @intCast(try sys.check(l.fork()));
    if (pid == 0) {
        _ = sys.check(l.chdir(cwd)) catch l.exit_group(1);
        arm(uid, gid, state) catch |err| {
            sys.writeAll(2, @errorName(err)) catch {};
            l.exit_group(2);
        };
        var actual: [4096]u8 = undefined;
        const n = sys.check(l.getcwd(&actual, actual.len)) catch l.exit_group(3);
        if (!std.mem.eql(u8, cwd, actual[0 .. n - 1])) l.exit_group(4);
        if (l.errno(l.open(outside, .{}, 0)) != .NOENT) l.exit_group(5);
        if (l.errno(l.open("../sibling", .{}, 0)) != .NOENT) l.exit_group(6);
        for ([_][:0]const u8{ "state/scopes/first/receipt", "state/scopes/second/receipt" }) |path| {
            if (l.errno(l.open(path, .{ .ACCMODE = .WRONLY }, 0)) != .ROFS) l.exit_group(7);
        }
        sys.writeFileAt(l.AT.FDCWD, "payload", "changed\n") catch l.exit_group(8);
        if (l.errno(l.socket(l.AF.UNIX, l.SOCK.STREAM, 0)) != .PERM) l.exit_group(9);
        const argv = [_:null]?[*:0]const u8{"./project-command"};
        const env = [_:null]?[*:0]const u8{};
        _ = l.execve("./project-command", &argv, &env);
        l.exit_group(10);
    }
    try std.testing.expectEqual(@as(u32, 0), try sys.wait(pid));
}

test "a whole temporary root cannot be restored as the project" {
    for ([_][:0]const u8{ "/tmp", "/var/tmp" }) |root| {
        const pid: l.pid_t = @intCast(try sys.check(l.fork()));
        if (pid == 0) {
            _ = sys.check(l.chdir(root)) catch l.exit_group(1);
            namespaces(l.getuid(), l.getgid(), "/unused") catch |err|
                l.exit_group(if (err == error.WorkingDirectoryAtTemporaryRoot) 0 else 2);
            l.exit_group(3);
        }
        try std.testing.expectEqual(@as(u32, 0), try sys.wait(pid));
    }
}

test "seccomp installs and refuses Unix sockets, namespaces and io_uring in a disposable child" {
    const pid: l.pid_t = @intCast(try sys.check(l.fork()));
    if (pid == 0) {
        seccomp() catch l.exit_group(1);
        if (l.errno(l.socket(l.AF.UNIX, l.SOCK.STREAM, 0)) != .PERM) l.exit_group(2);
        if (l.errno(l.unshare(l.CLONE.NEWUSER)) != .PERM) l.exit_group(3);
        if (l.errno(l.syscall2(.io_uring_setup, 1, 0)) != .PERM) l.exit_group(4);
        const tcp = l.socket(l.AF.INET, l.SOCK.STREAM, 0);
        if (l.errno(tcp) != .SUCCESS) l.exit_group(5);
        sys.close(@intCast(tcp));
        if (l.errno(l.socket(l.AF.INET, l.SOCK.RAW, 1)) != .PERM) l.exit_group(6);
        if (l.errno(l.socket(l.AF.INET, l.SOCK.STREAM, 132)) != .PERM) l.exit_group(7); // SCTP
        if (l.errno(l.socket(l.AF.INET, l.SOCK.DGRAM, 1)) != .PERM) l.exit_group(8); // ping v4
        if (l.errno(l.socket(l.AF.INET6, l.SOCK.DGRAM, 58)) != .PERM) l.exit_group(9); // ping v6
        if (l.errno(l.socket(l.AF.INET, l.SOCK.STREAM, 262)) != .PERM) l.exit_group(10); // MPTCP
        if (l.errno(l.socket(l.AF.INET6, l.SOCK.STREAM, 132)) != .PERM) l.exit_group(11); // SCTP v6
        if (l.errno(l.socket(l.AF.INET, l.SOCK.DGRAM, 136)) != .PERM) l.exit_group(12); // UDPLITE
        for ([_]u32{ l.AF.INET, l.AF.INET6 }) |family| {
            for ([_]struct { kind: u32, protocol: u32 }{
                .{ .kind = l.SOCK.STREAM, .protocol = 6 },
                .{ .kind = l.SOCK.DGRAM, .protocol = 17 },
            }) |s| {
                const fd = l.socket(family, s.kind, s.protocol);
                if (l.errno(fd) != .SUCCESS) l.exit_group(13);
                sys.close(@intCast(fd));
            }
        }
        l.exit_group(0);
    }
    try std.testing.expectEqual(@as(u32, 0), try sys.wait(pid));
}
