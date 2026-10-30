//! Unprivileged launcher descriptor handling. The helper receives only the selected stdin.
const std = @import("std");
const sys = @import("sys.zig");
const l = sys.l;

/// Open before fork. The caller owns the descriptor; null means inherit stdin.
pub fn prepareStdin(null_device: bool) !?l.fd_t {
    if (!null_device) return null;
    const fd = try sys.fd(l.open("/dev/null", .{ .CLOEXEC = true, .NOFOLLOW = true }, 0));
    errdefer sys.close(fd);
    if (fd == 1 or fd == 2) return error.InvalidState;
    const stat = try sys.stat(fd);
    if (stat.mode & 0o170000 != 0o020000 or stat.rdev_major != 1 or stat.rdev_minor != 3) return error.NullDeviceRequired;
    return fd;
}

pub fn ensureStdio(replacement: ?l.fd_t) !void {
    for (0..3) |i| {
        const fd: l.fd_t = if (i == 0) replacement orelse 0 else @intCast(i);
        if ((try sys.stat(fd)).mode & 0o170000 == 0o140000) return error.SocketStdioRefused;
    }
}

/// Syscalls only, after fork and before descriptors 3+ are rearranged/closed.
pub fn setStdin(replacement: ?l.fd_t) !void {
    const fd = replacement orelse return;
    if (fd == 0) {
        // If stdin was closed, open(/dev/null) may have returned 0 with CLOEXEC set.
        _ = try sys.check(l.fcntl(0, l.F.SETFD, 0));
    } else {
        _ = try sys.check(l.dup3(fd, 0, 0));
    }
}

test "relay stdin replacement prevents seeking back to consumed synthetic credentials" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input = try tmp.dir.createFile(std.testing.io, "input", .{ .read = true });
    defer input.close(std.testing.io);
    const token = "synthetic-relay-key\n";
    try input.writePositionalAll(std.testing.io, token, 0);
    for ([_]bool{ false, true }) |replace| {
        const pid: l.pid_t = @intCast(try sys.check(l.fork()));
        if (pid == 0) {
            _ = sys.check(l.dup3(input.handle, 0, 0)) catch l.exit_group(1);
            _ = sys.check(l.lseek(0, token.len, 0)) catch l.exit_group(2);
            const replacement = prepareStdin(replace) catch l.exit_group(3);
            ensureStdio(replacement) catch l.exit_group(4);
            setStdin(replacement) catch l.exit_group(5);
            if (replacement) |fd| if (fd != 0) sys.close(fd);
            _ = sys.check(l.lseek(0, 0, 0)) catch l.exit_group(6);
            var buf: [64]u8 = undefined;
            const n = sys.read(0, &buf) catch l.exit_group(7);
            if (replace) {
                if (n != 0) l.exit_group(8);
            } else if (!std.mem.eql(u8, token, buf[0..n])) l.exit_group(9);
            l.exit_group(0);
        }
        try std.testing.expectEqual(@as(u32, 0), try sys.wait(pid));
    }
}

test "replacing socket stdin is allowed but inheriting it is refused" {
    var sockets: [2]l.fd_t = undefined;
    _ = try sys.check(l.socketpair(l.AF.UNIX, l.SOCK.STREAM | l.SOCK.CLOEXEC, 0, &sockets));
    defer sys.close(sockets[0]);
    defer sys.close(sockets[1]);
    const pid: l.pid_t = @intCast(try sys.check(l.fork()));
    if (pid == 0) {
        _ = sys.check(l.dup3(sockets[0], 0, 0)) catch l.exit_group(1);
        if (ensureStdio(null)) |_| {
            l.exit_group(2);
        } else |err| if (err != error.SocketStdioRefused) l.exit_group(3);
        const replacement = prepareStdin(true) catch l.exit_group(4);
        ensureStdio(replacement) catch l.exit_group(5);
        setStdin(replacement) catch l.exit_group(6);
        sys.ensureStdio() catch l.exit_group(7);
        l.exit_group(0);
    }
    try std.testing.expectEqual(@as(u32, 0), try sys.wait(pid));
}

test "replacement stdin survives exec when open returned descriptor zero" {
    const pid: l.pid_t = @intCast(try sys.check(l.fork()));
    if (pid == 0) {
        sys.close(0);
        const replacement = prepareStdin(true) catch l.exit_group(1);
        if (replacement != 0) l.exit_group(2);
        setStdin(replacement) catch l.exit_group(3);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "test -c /proc/self/fd/0 && test ! -s /proc/self/fd/0" };
        const env = [_:null]?[*:0]const u8{};
        _ = l.execve("/bin/sh", &argv, &env);
        l.exit_group(4);
    }
    try std.testing.expectEqual(@as(u32, 0), try sys.wait(pid));
}

test "replacement stdin refuses closed output descriptors in the launcher" {
    for ([_]l.fd_t{ 1, 2 }) |output| {
        const pid: l.pid_t = @intCast(try sys.check(l.fork()));
        if (pid == 0) {
            sys.close(output);
            if (prepareStdin(true)) |_| {
                l.exit_group(1);
            } else |err| if (err != error.InvalidState) l.exit_group(2);
            // The failed replacement must not leave /dev/null in the missing output slot.
            if (l.errno(l.fcntl(output, l.F.GETFD, 0)) != .BADF) l.exit_group(3);
            l.exit_group(0);
        }
        try std.testing.expectEqual(@as(u32, 0), try sys.wait(pid));
    }
}
