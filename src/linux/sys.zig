//! Small syscall-only primitives, also safe between fork and exec in a threaded caller.
const std = @import("std");
pub const l = std.os.linux;
pub const Error = error{ PermissionDenied, UnsupportedKernel, KernelFailure, UnexpectedEof, InvalidState };

pub fn check(rc: usize) Error!usize {
    return switch (l.errno(rc)) {
        .SUCCESS => rc,
        .ACCES, .PERM => error.PermissionDenied,
        .NOSYS, .OPNOTSUPP => error.UnsupportedKernel,
        else => error.KernelFailure,
    };
}
pub fn fd(rc: usize) Error!l.fd_t {
    return @intCast(try check(rc));
}
pub fn close(f: l.fd_t) void {
    _ = l.close(f);
}
pub fn pipe() Error![2]l.fd_t {
    var p: [2]l.fd_t = undefined;
    _ = try check(l.pipe2(&p, .{ .CLOEXEC = true }));
    return p;
}
pub fn writeAll(f: l.fd_t, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = l.write(f, bytes[offset..].ptr, bytes.len - offset);
        if (l.errno(rc) == .INTR) continue;
        const n = try check(rc);
        if (n == 0) return error.UnexpectedEof;
        offset += n;
    }
}
pub fn read(f: l.fd_t, bytes: []u8) Error!usize {
    while (true) {
        const rc = l.read(f, bytes.ptr, bytes.len);
        if (l.errno(rc) == .INTR) continue;
        return check(rc);
    }
}
pub fn readFull(f: l.fd_t, bytes: []u8) Error!bool {
    var n: usize = 0;
    while (n < bytes.len) {
        const got = try read(f, bytes[n..]);
        if (got == 0) {
            if (n == 0) return false;
            return error.UnexpectedEof;
        }
        n += got;
    }
    return true;
}
pub fn writeFileAt(dir: l.fd_t, name: [:0]const u8, bytes: []const u8) Error!void {
    const f = try fd(l.openat(dir, name, .{ .ACCMODE = .WRONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0));
    defer close(f);
    try writeAll(f, bytes);
}
pub fn readFileAt(dir: l.fd_t, name: [:0]const u8, bytes: []u8) Error![]u8 {
    const f = try fd(l.openat(dir, name, .{ .CLOEXEC = true, .NOFOLLOW = true }, 0));
    defer close(f);
    const n = try read(f, bytes);
    if (n == bytes.len) return error.InvalidState;
    return bytes[0..n];
}
pub fn stat(f: l.fd_t) Error!l.Statx {
    var s: l.Statx = undefined;
    _ = try check(l.statx(f, "", l.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true, .GID = true, .INO = true }, &s));
    if (!s.mask.TYPE or !s.mask.MODE or !s.mask.UID or !s.mask.INO) return error.UnsupportedKernel;
    return s;
}
pub fn rootOwned(f: l.fd_t) Error!void {
    const s = try stat(f);
    if (s.uid != 0 or s.mode & 0o022 != 0) return error.InvalidState;
}
pub fn noNewPrivileges() Error!void {
    _ = try check(l.prctl(@backingInt(l.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0));
}
pub fn nonDumpable() Error!void {
    _ = try check(l.prctl(@backingInt(l.PR.SET_DUMPABLE), 0, 0, 0, 0));
}
// The UAPI header is two u32s (do not use a libc-dependent capability wrapper).
pub const CapHeader = extern struct { version: u32 = 0x20080522, pid: i32 = 0 };
pub const Caps = extern struct { effective: u32 = 0, permitted: u32 = 0, inheritable: u32 = 0 };
pub fn capabilities() Error![2]Caps {
    var hdr: CapHeader = .{};
    var data: [2]Caps = undefined;
    _ = try check(l.syscall2(.capget, @intFromPtr(&hdr), @intFromPtr(&data)));
    return data;
}
pub fn dropCapabilities() Error!void {
    var hdr: CapHeader = .{};
    const data: [2]Caps = .{ .{}, .{} };
    _ = try check(l.syscall2(.capset, @intFromPtr(&hdr), @intFromPtr(&data)));
}
pub fn requireCapabilities() Error!void {
    const caps = try capabilities();
    // CAP_CHOWN, CAP_DAC_OVERRIDE, CAP_NET_ADMIN, CAP_BPF. No CAP_SYS_ADMIN.
    const low = (@as(u32, 1) << 0) | (1 << 1) | (1 << 12);
    const high = @as(u32, 1) << (39 - 32);
    if (caps[0].effective & low != low or caps[1].effective & high != high) return error.PermissionDenied;
}
pub fn wait(pid: l.pid_t) Error!u32 {
    var status: i32 = 0;
    while (true) {
        const rc = l.waitpid(pid, &status, 0);
        if (l.errno(rc) == .INTR) continue;
        _ = try check(rc);
        return @bitCast(status);
    }
}
pub fn poll(fds: []l.pollfd, timeout: i32) Error!usize {
    while (true) {
        const rc = l.poll(fds.ptr, fds.len, timeout);
        if (l.errno(rc) == .INTR) continue;
        return check(rc);
    }
}
pub fn ensureStdio() Error!void {
    for (0..3) |i| {
        const s = try stat(@intCast(i));
        // Sockets would retain their original cgroup attribution. Never inherit them.
        if (s.mode & 0o170000 == 0o140000) return error.InvalidState;
    }
}

test "outside sockets cannot be used as workload stdio" {
    var sockets: [2]l.fd_t = undefined;
    _ = try check(l.socketpair(l.AF.UNIX, l.SOCK.STREAM | l.SOCK.CLOEXEC, 0, &sockets));
    defer close(sockets[0]);
    defer close(sockets[1]);
    const pid: l.pid_t = @intCast(try check(l.fork()));
    if (pid == 0) {
        _ = check(l.dup2(sockets[0], 0)) catch l.exit_group(1);
        ensureStdio() catch |err| l.exit_group(if (err == error.InvalidState) 0 else 2);
        l.exit_group(3);
    }
    try std.testing.expectEqual(@as(u32, 0), try wait(pid));
}
