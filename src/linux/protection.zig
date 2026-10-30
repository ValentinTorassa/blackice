//! Read-only trusted files and non-renamable ancestors in the child's private mount namespace.
const std = @import("std");
const sys = @import("sys.zig");
const l = sys.l;
const wire = @import("protocol.zig");

pub fn below(path: []const u8, parent: []const u8) bool {
    return std.mem.eql(u8, path, parent) or
        (path.len > parent.len and std.mem.startsWith(u8, path, parent) and path[parent.len] == '/');
}

pub fn maskedRoot(path: []const u8) ?[]const u8 {
    for ([_][]const u8{ "/tmp", "/var/tmp", "/run", "/var/run" }) |root| if (below(path, root)) return root;
    return null;
}

pub fn pin(path: [:0]const u8) !l.fd_t {
    if (!wire.validPath(path)) return error.InvalidProtectedPath;
    const How = extern struct { flags: u64, mode: u64 = 0, resolve: u64 = 0x06 };
    const how: How = .{ .flags = @as(u32, @bitCast(l.O{ .PATH = true, .CLOEXEC = true, .NOFOLLOW = true })) };
    const rc = l.syscall4(.openat2, @bitCast(@as(isize, l.AT.FDCWD)), @intFromPtr(path.ptr), @intFromPtr(&how), @sizeOf(How));
    if (l.errno(rc) == .LOOP) return error.ProtectedPathMustBeCanonical;
    return sys.fd(rc);
}

fn metadata(fd: l.fd_t) !l.Statx {
    var s: l.Statx = undefined;
    _ = try sys.check(l.statx(fd, "", l.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .NLINK = true, .INO = true, .MNT_ID = true }, &s));
    if (!s.mask.TYPE or !s.mask.NLINK or !s.mask.INO or !s.mask.MNT_ID) return error.ProtectionMetadataUnavailable;
    return s;
}

fn same(a: l.Statx, b: l.Statx) bool {
    return a.dev_major == b.dev_major and a.dev_minor == b.dev_minor and a.ino == b.ino;
}

const Pinned = struct {
    path: [:0]const u8,
    fd: l.fd_t,
    stat: l.Statx,

    fn open(path: [:0]const u8, directory: bool) !Pinned {
        const fd = try pin(path);
        errdefer sys.close(fd);
        const s = try metadata(fd);
        const kind = s.mode & 0o170000;
        if (if (directory) kind != 0o040000 else kind != 0o100000 and kind != 0o120000) return error.ProtectedFileOrSymlinkRequired;
        // A read-only bind alone leaves pre-existing hard links writable through their other names.
        if (!directory and s.nlink != 1) return error.ProtectedFileHasHardLinks;
        return .{ .path = path, .fd = fd, .stat = s };
    }

    fn verify(p: Pinned) !void {
        const fd = try pin(p.path);
        defer sys.close(fd);
        const current = try metadata(fd);
        if (!same(p.stat, current) or current.nlink != p.stat.nlink) return error.ProtectedPathChanged;
    }
};

pub const Prepared = struct {
    state: Pinned,
    files: [wire.max_protected]Pinned = undefined,
    len: usize = 0,

    /// Called after dropping host capabilities and making mount propagation private, before any new binds.
    pub fn init(state: [:0]const u8, paths: []const [:0]const u8) !Prepared {
        if (paths.len > wire.max_protected) return error.TooManyProtectedPaths;
        if (maskedRoot(state)) |root| if (std.mem.eql(u8, root, state)) return error.StateRootNotSpecific;
        var p: Prepared = .{ .state = try Pinned.open(state, true) };
        errdefer p.close();
        for (paths) |path| {
            var duplicate = false;
            for (p.files[0..p.len]) |other| duplicate = duplicate or std.mem.eql(u8, other.path, path);
            if (duplicate) continue;
            p.files[p.len] = try Pinned.open(path, false);
            p.len += 1;
        }
        // Conservatively refuse existing alternate mount views of these filesystems. Such aliases are
        // not counted by st_nlink and would bypass a read-only bind of just the canonical path.
        var table: [65536]u8 = undefined;
        const fd = try sys.fd(l.open("/proc/self/mountinfo", .{ .CLOEXEC = true }, 0));
        defer sys.close(fd);
        var n: usize = 0;
        while (n < table.len) {
            const got = try sys.read(fd, table[n..]);
            if (got == 0) break;
            n += got;
        }
        if (n == table.len) return error.ProtectionMountTableTooLarge;
        try singleView(p.state.stat, table[0..n]);
        for (p.files[0..p.len]) |f| try singleView(f.stat, table[0..n]);
        try p.checkStdio();
        return p;
    }

    fn checkStdio(p: *const Prepared) !void {
        // A bind does not revoke an already-open descriptor's original writable mount. Even a
        // read-only file descriptor can change metadata; a directory descriptor exposes its subtree.
        for (0..3) |i| {
            const s = try metadata(@intCast(i));
            if (s.mode & 0o170000 == 0o040000) return error.DirectoryStdioNotAllowed;
            if (s.mode & 0o170000 != 0o100000) continue;
            for (p.files[0..p.len]) |f| if (same(s, f.stat)) return error.ProtectedStdioNotAllowed;
            var fd_buf: [32]u8 = undefined;
            const path = try std.fmt.bufPrintSentinel(&fd_buf, "/proc/self/fd/{d}", .{i}, 0);
            var target: [4096]u8 = undefined;
            const size = try sys.check(l.readlink(path, &target, target.len));
            if (size == target.len) return error.ProtectedStdioNotAllowed;
            if (below(target[0..size], p.state.path)) return error.ProtectedStdioNotAllowed;
        }
    }

    pub fn close(p: *Prepared) void {
        sys.close(p.state.fd);
        for (p.files[0..p.len]) |f| sys.close(f.fd);
    }

    pub fn protectState(p: *Prepared) !void {
        try bindReadOnly(p.state, true, true);
        // The temporary-project bind must inherit the read-only state submount.
        const fd = try pin(p.state.path);
        sys.close(p.state.fd);
        p.state.fd = fd;
    }

    /// Restore only explicitly trusted objects outside a temporary cwd, never the surrounding host tree.
    pub fn restore(p: *Prepared, cwd: []const u8) !void {
        if (maskedRoot(p.state.path)) |root| {
            if (!below(p.state.path, cwd)) {
                try makePrivateParents(p.state.path, root.len, true);
                try bindReadOnly(p.state, true, true);
            }
        }
        for (p.files[0..p.len]) |f| {
            if (maskedRoot(f.path)) |root| {
                if (!below(f.path, cwd) and !below(f.path, p.state.path)) {
                    try makePrivateParents(f.path, root.len, false);
                    const fd = try sys.fd(l.open(f.path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, 0o600));
                    sys.close(fd);
                    try bindReadOnly(f, false, false);
                }
            }
        }
    }

    pub fn finish(p: *Prepared) !void {
        var ancestors: Ancestors = .{};
        try ancestors.add(p.state.path);
        for (p.files[0..p.len]) |f| try ancestors.add(f.path);
        try ancestors.arm();
        for (p.files[0..p.len]) |f| {
            try f.verify();
            try bindReadOnly(f, false, below(f.path, p.state.path));
            try f.verify();
        }
        try p.state.verify();
    }
};

fn singleView(s: l.Statx, table: []const u8) !void {
    var device_buf: [32]u8 = undefined;
    const device = try std.fmt.bufPrint(&device_buf, "{d}:{d}", .{ s.dev_major, s.dev_minor });
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse return error.InvalidMountTable;
        _ = fields.next() orelse return error.InvalidMountTable;
        const dev = fields.next() orelse return error.InvalidMountTable;
        if (std.mem.eql(u8, dev, device)) count += 1;
    }
    if (count != 1) return error.ProtectionFilesystemHasAliases;
}

fn bindReadOnly(p: Pinned, recursive: bool, noexec: bool) !void {
    var source_buf: [64]u8 = undefined;
    const source = try std.fmt.bufPrintSentinel(&source_buf, "/proc/self/fd/{d}", .{p.fd}, 0);
    // Both descriptors pin the object itself. For a final symlink this avoids following its target.
    const targetfd = try pin(p.path);
    defer sys.close(targetfd);
    var target_buf: [64]u8 = undefined;
    const target = try std.fmt.bufPrintSentinel(&target_buf, "/proc/self/fd/{d}", .{targetfd}, 0);
    _ = try sys.check(l.mount(source, target, null, l.MS.BIND | @as(u32, if (recursive) l.MS.REC else 0), 0));
    const Attr = extern struct { set: u64, clear: u64 = 0, propagation: u64 = 0, userns: u64 = 0 };
    const attr: Attr = .{ .set = 1 | 2 | 4 | @as(u64, if (noexec) 8 else 0) }; // RDONLY|NOSUID|NODEV, optionally NOEXEC
    _ = try sys.check(l.syscall5(.mount_setattr, @bitCast(@as(isize, l.AT.FDCWD)), @intFromPtr(p.path.ptr), 0x100 | @as(usize, if (recursive) 0x8000 else 0), @intFromPtr(&attr), @sizeOf(Attr)));
}

fn makePrivateParents(path: [:0]const u8, root_len: usize, include_leaf: bool) !void {
    var buf: [4096]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    for (root_len + 1..path.len + 1) |i| {
        if (i == path.len) {
            if (!include_leaf) break;
        } else if (buf[i] != '/') continue;
        const saved = buf[i];
        buf[i] = 0;
        const rc = l.mkdirat(l.AT.FDCWD, @ptrCast(&buf), 0o700);
        if (l.errno(rc) != .EXIST) _ = try sys.check(rc);
        const fd = try pin(buf[0..i :0]);
        defer sys.close(fd);
        if ((try metadata(fd)).mode & 0o170000 != 0o040000) return error.InvalidPrivateParent;
        buf[i] = saved;
    }
}

const Ancestors = struct {
    paths: [256][]const u8 = undefined,
    len: usize = 0,

    fn add(a: *Ancestors, path: []const u8) !void {
        // Gathering each chain root-first and deduplicating avoids recursively copying already-bound parents.
        for (path[1..], 1..) |c, i| {
            if (c != '/') continue;
            const prefix = path[0..i];
            var exists = false;
            for (a.paths[0..a.len]) |prior| exists = exists or std.mem.eql(u8, prior, prefix);
            if (exists) continue;
            if (a.len == a.paths.len) return error.TooManyProtectedAncestors;
            a.paths[a.len] = prefix;
            a.len += 1;
        }
    }

    fn arm(a: *const Ancestors) !void {
        for (a.paths[0..a.len]) |path| {
            var buf: [4096]u8 = undefined;
            @memcpy(buf[0..path.len], path);
            buf[path.len] = 0;
            const target = buf[0..path.len :0];
            const fd = try pin(target);
            defer sys.close(fd);
            const s = try metadata(fd);
            if (s.mode & 0o170000 != 0o040000) return error.InvalidProtectedAncestor;
            // Existing mount points already reject rename/rmdir. Compare with the parent's mount ID.
            const slash = std.mem.findScalarLast(u8, path, '/').?;
            var parent_buf: [4096]u8 = undefined;
            const parent = if (slash == 0) "/" else path[0..slash];
            @memcpy(parent_buf[0..parent.len], parent);
            parent_buf[parent.len] = 0;
            const parentfd = if (parent.len == 1) try sys.fd(l.open("/", .{ .PATH = true, .CLOEXEC = true }, 0)) else try pin(parent_buf[0..parent.len :0]);
            defer sys.close(parentfd);
            if (s.mnt_id != (try metadata(parentfd)).mnt_id) continue;
            var source_buf: [64]u8 = undefined;
            const source = try std.fmt.bufPrintSentinel(&source_buf, "/proc/self/fd/{d}", .{fd}, 0);
            _ = try sys.check(l.mount(source, target, null, l.MS.BIND | l.MS.REC, 0));
            const current = try pin(target);
            defer sys.close(current);
            if (!same(s, try metadata(current))) return error.ProtectedAncestorChanged;
        }
    }
};
