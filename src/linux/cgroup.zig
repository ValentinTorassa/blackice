const std = @import("std");
const sys = @import("sys.zig");
const l = sys.l;
const protocol = @import("protocol.zig");

pub const Scope = struct {
    root: l.fd_t,
    dir: l.fd_t,
    name: [11:0]u8 = @splat(0),
    removed: bool = false,

    pub fn create(id: []const u8) !Scope {
        if (!protocol.validScope(id)) return error.InvalidScope;
        const root = try sys.fd(l.open(protocol.cgroup_root, .{ .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0));
        errdefer sys.close(root);
        try sys.rootOwned(root);
        const rs = try sys.stat(root);
        // The parent is deliberately not traversable by the workload, even during mkdir/chown.
        if (rs.mode & 0o777 != 0o700) return error.CgroupRootMustBePrivate;
        var s: Scope = .{ .root = root, .dir = -1 };
        @memcpy(s.name[0..id.len], id);
        _ = try sys.check(l.mkdirat(root, &s.name, 0o700));
        errdefer _ = l.unlinkat(root, &s.name, l.AT.REMOVEDIR);
        s.dir = try sys.fd(l.openat(root, &s.name, .{ .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0));
        errdefer sys.close(s.dir);
        _ = try sys.check(l.fchown(s.dir, 0, 0));
        _ = try sys.check(l.fchmod(s.dir, 0o700));
        for ([_][:0]const u8{ "cgroup.procs", "cgroup.threads", "cgroup.subtree_control", "cgroup.type", "cgroup.freeze", "cgroup.kill", "cgroup.max.depth", "cgroup.max.descendants" }) |path| {
            _ = try sys.check(l.fchownat(s.dir, path, 0, 0, l.AT.SYMLINK_NOFOLLOW));
        }
        try sys.writeFileAt(s.dir, "cgroup.max.descendants", "0\n");
        try sys.writeFileAt(s.dir, "cgroup.max.depth", "0\n");
        return s;
    }
    pub fn enroll(s: *Scope, child: l.pid_t) !void {
        var pidbuf: [24]u8 = undefined;
        try sys.writeFileAt(s.dir, "cgroup.procs", try std.fmt.bufPrint(&pidbuf, "{d}\n", .{child}));
        var buf: [256]u8 = undefined;
        const actual = try sys.readFileAt(s.dir, "cgroup.procs", &buf);
        if (!std.mem.eql(u8, actual, try std.fmt.bufPrint(&pidbuf, "{d}\n", .{child}))) return error.EnrollmentNotVerified;
    }
    pub fn kill(s: *Scope) !void {
        try sys.writeFileAt(s.dir, "cgroup.kill", "1\n");
    }
    pub fn empty(s: *Scope) !bool {
        var buf: [256]u8 = undefined;
        const events = try sys.readFileAt(s.dir, "cgroup.events", &buf);
        return std.mem.startsWith(u8, events, "populated 0\n");
    }
    pub fn cleanup(s: *Scope) !void {
        try s.kill();
        for (0..200) |_| {
            if (try s.empty()) {
                // The kernel removes the attached programs when the cgroup dies. Never detach a live scope.
                _ = try sys.check(l.unlinkat(s.root, &s.name, l.AT.REMOVEDIR));
                s.removed = true;
                return;
            }
            _ = try sys.poll(&.{}, 10);
        }
        return error.CgroupStillPopulated;
    }
    pub fn close(s: *Scope) void {
        sys.close(s.dir);
        sys.close(s.root);
    }
};

pub fn requireHostNamespaces() !void {
    // Root records these at install time. Reading /proc/1/ns would require CAP_SYS_PTRACE.
    const config = try sys.fd(l.open("/etc/blackice-linux/namespaces", .{ .CLOEXEC = true, .NOFOLLOW = true }, 0));
    defer sys.close(config);
    try sys.rootOwned(config);
    var expected_buf: [512]u8 = undefined;
    const n = try sys.read(config, &expected_buf);
    if (n == expected_buf.len) return error.InvalidNamespaceConfig;
    var expected = std.mem.splitScalar(u8, expected_buf[0..n], '\n');
    for ([_][:0]const u8{ "user", "mnt", "net", "cgroup", "pid" }) |name| {
        var path: [64]u8 = undefined;
        var target: [64]u8 = undefined;
        const len = try sys.check(l.readlink(try std.fmt.bufPrintSentinel(&path, "/proc/self/ns/{s}", .{name}, 0), &target, target.len));
        if (!std.mem.eql(u8, target[0..len], expected.next() orelse return error.InvalidNamespaceConfig)) return error.HostNamespacesRequired;
    }
    if (!std.mem.eql(u8, expected.next() orelse return error.InvalidNamespaceConfig, "") or expected.next() != null) return error.InvalidNamespaceConfig;
    // Check the mount type with statfs, not just a filename under /sys.
    // statfs UAPI is at most 120 bytes on the two supported 64-bit architectures; f_type is first.
    var fs: [32]u64 = @splat(0);
    _ = try sys.check(l.syscall2(.statfs, @intFromPtr("/sys/fs/cgroup"), @intFromPtr(&fs)));
    if (fs[0] != 0x63677270) return error.CgroupV2Required;
}
